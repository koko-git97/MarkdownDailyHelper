function Invoke-MdhStartupDb {
    $operation = 'status'
    try {
        $response = Invoke-MdhDbCommand -Operation $operation
        Assert-MdhStartupDbResponse -Response $response -Operation $operation
        $state = $response.result
        if ($state.initialized -isnot [bool] -or $state.incomplete -isnot [bool]) {
            throw 'DB 状態の初期化フラグまたは完全性フラグが不正です。'
        }
        foreach ($name in 'generation', 'counts', 'last_attempt', 'last_full_success') {
            if (-not $state.PSObject.Properties[$name]) {
                throw "DB 状態に $name がありません。"
            }
        }
        foreach ($name in 'CURRENT', 'STALE', 'INVALID', 'MISSING', 'DELETED') {
            $count = $state.counts.$name
            if (($count -isnot [int] -and $count -isnot [long]) -or $count -lt 0 -or
                (-not $state.initialized -and $count -ne 0)) {
                throw "DB 状態の $name 件数が不正です。"
            }
        }
        if ($state.initialized) {
            if ($state.generation -isnot [string] -or $state.generation -cnotmatch '^db-[a-f0-9]{32}\.sqlite\z') {
                throw 'DB の世代名が不正です。'
            }
        }
        elseif ($null -ne $state.generation -or $null -ne $state.last_attempt -or
            $null -ne $state.last_full_success -or -not $state.incomplete) {
            throw 'DB が正常な未初期化状態であることを確認できません。'
        }

        $arguments = @()
        if ($state.initialized) {
            $operation = 'sync'
        }
        else {
            $operation = 'rebuild'
            $arguments = @('--only-if-uninitialized')
        }
        Write-Verbose "DB $operation"
        $response = Invoke-MdhDbCommand -Operation $operation -Arguments $arguments
        Assert-MdhStartupDbResponse -Response $response -Operation $operation
        $result = $response.result
        if ($operation -eq 'sync') {
            if ($result.completed -isnot [bool] -or
                ($result.failed -isnot [int] -and $result.failed -isnot [long]) -or
                ($result.missing -isnot [int] -and $result.missing -isnot [long]) -or
                $result.failed -lt 0 -or $result.missing -lt 0 -or
                -not $result.PSObject.Properties['scan_error'] -or $null -ne $result.scan_error) {
                throw 'Sync の結果が不正です。'
            }
            if ($response.exit_code -eq 1 -or -not $result.completed -or
                $result.failed -ne 0 -or $result.missing -ne 0 -or $response.diagnostics.Count -gt 0 -or
                ($result.PSObject.Properties['incomplete'] -and $result.incomplete -ne $false)) {
                $detail = $response.diagnostics.code -join ', '
                Write-Warning "DB Sync は不完全です（failed=$($result.failed), missing=$($result.missing)）。$detail"
                return 'Sync WARNING'
            }
        }
        elseif ([string]::IsNullOrWhiteSpace($result.path) -or
            ($result.indexed -isnot [int] -and $result.indexed -isnot [long]) -or $result.indexed -lt 0) {
            throw 'Rebuild の結果が不正です。'
        }
        return "$operation OK"
    }
    catch {
        Write-Warning "DB ${operation}: $($_.Exception.Message)"
        return "$operation FAILED"
    }
}

function Assert-MdhStartupDbResponse {
    param($Response, [string]$Operation)

    if ($Response -isnot [pscustomobject] -or $Response.operation -cne $Operation -or
        ($Response.contract_version -isnot [int] -and $Response.contract_version -isnot [long]) -or
        $Response.contract_version -ne 1 -or
        ($Response.exit_code -isnot [int] -and $Response.exit_code -isnot [long]) -or
        $Response.diagnostics -isnot [array]) {
        throw 'DB の応答形式が不正です。'
    }
    if ($Response.exit_code -ne 0 -and ($Operation -ne 'sync' -or $Response.exit_code -ne 1)) {
        $detail = ($Response.diagnostics | ForEach-Object { "$($_.code) $($_.message)" }) -join ' / '
        throw "終了コード $($Response.exit_code)。$detail"
    }
    if ($Response.result -isnot [pscustomobject] -or ($Operation -ne 'sync' -and $Response.diagnostics.Count -ne 0)) {
        throw 'DB の結果または診断情報が不正です。'
    }
}

function Open-MdhStartupFiles {
    [CmdletBinding()]
    param([string]$DateText)

    $opened = 0
    $warnings = 0
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $entries = $script:MDH_CONFIG.startup.open_files
    if ($null -ne $entries -and $entries -isnot [array]) {
        Write-Warning 'startup.open_files は配列で指定してください。'
        return '0 items, 1 warning'
    }

    foreach ($entry in $entries) {
        try {
            if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) {
                throw '表示対象は空でない文字列で指定してください。'
            }
            $path = switch ($entry) {
                '{todo}' { Get-MdhTodoPath }
                '{quicknotes}' { $script:MDH_CONFIG.paths.quicknotes }
                '{today_daily}' { Get-MdhDailyPath -DateText $DateText }
                '{previous_daily}' {
                    $previous = Get-MdhLastDailyDate -BeforeDate $DateText
                    if ($previous) { Get-MdhDailyPath -DateText $previous }
                }
                default {
                    if ($entry -match '[{}]') { throw '未定義のプレースホルダーです。' }
                    Get-MdhDbAbsolutePath -Root $script:MDHRoot -Value $entry
                }
            }
            if (-not $path -and $entry -eq '{previous_daily}') { continue }
            if (-not $path -or -not (Test-Path -LiteralPath $path)) { throw '表示対象が見つかりません。' }

            $item = Get-Item -LiteralPath $path -Force
            if (($entry -eq '{quicknotes}' -and -not $item.PSIsContainer) -or
                ($entry -in '{todo}', '{today_daily}', '{previous_daily}' -and $item.PSIsContainer)) {
                throw '表示対象のファイル種別が設定と一致しません。'
            }
            $normalized = [IO.Path]::TrimEndingDirectorySeparator($item.FullName)
            if ($seen.Add($normalized)) {
                Open-IfExist -Path $normalized -RequireCode
                $opened++
            }
        }
        catch {
            Write-Warning "Open ($entry): $($_.Exception.Message)"
            $warnings++
        }
    }
    $itemLabel = if ($opened -eq 1) { 'item' } else { 'items' }
    $requests = "Requested $opened $itemLabel"
    if ($warnings -eq 1) { return "$requests, 1 warning" }
    if ($warnings -gt 1) { return "$requests, $warnings warnings" }
    return $requests
}

<#
.SYNOPSIS
当日の日報・TODO・検索用DBを準備します。
.DESCRIPTION
Daily、TODO、DB の順に処理し、設定された項目を VS Code に表示要求します。前段の失敗に応じて後段を省略します。
.PARAMETER NoOpen
VS Code への表示要求を省略します。
.PARAMETER SkipDb
DB の状態確認・同期・再構築を省略します。
.EXAMPLE
mdstart -NoOpen -SkipDb
.NOTES
表示とDBを省略しても日報とTODOを更新することがあります。
#>
function mdstart {
    [CmdletBinding()]
    param([switch]$NoOpen, [switch]$SkipDb)

    $ErrorActionPreference = 'Stop'
    $dateText = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $dailyResult = 'FAILED'
    $todoResult = 'Skip (Daily failed)'
    $dbResult = 'Skip (Daily failed)'
    $openResult = 'Skip (-NoOpen)'
    $dailyWarnings = @()
    $todoWarnings = @()
    $openWarnings = @()

    try {
        Write-Verbose "Daily $dateText"
        Start-MdhDaily -DateText $dateText -NoOpen -WarningVariable dailyWarnings
        if (-not (Test-Path -LiteralPath (Get-MdhDailyPath -DateText $dateText) -PathType Leaf)) {
            throw '当日日報を確認できません。'
        }
        $dailyResult = 'OK'
    }
    catch {
        Write-Warning "Daily: $($_.Exception.Message)"
    }

    if ($dailyResult -eq 'OK') {
        $todoResult = 'FAILED'
        $dbResult = 'Skip (TODO failed)'
        try {
            Write-Verbose "TODO $dateText"
            Update-MdhTodo -DateText $dateText -NoOpen -RequireArchive -WarningVariable todoWarnings
            $todoResult = if ($todoWarnings.Count) { 'WARNING' } else { 'OK' }
        }
        catch {
            Write-Warning "TODO: $($_.Exception.Message)"
        }
        if ($todoResult -ne 'FAILED') {
            $dbResult = if ($SkipDb) { 'Skip (-SkipDb)' } else {
                Write-Verbose 'DB Status'
                Invoke-MdhStartupDb
            }
        }
    }
    if (-not $NoOpen) {
        try {
            Write-Verbose 'Open startup.open_files'
            $openResult = Open-MdhStartupFiles -DateText $dateText -WarningVariable openWarnings
        }
        catch {
            Write-Warning "Open: $($_.Exception.Message)"
            $openResult = '0 items, display failed'
            $openWarnings = @($_)
        }
    }

    $overall = if ($dailyResult -eq 'FAILED') { '失敗' }
    elseif ($todoResult -eq 'FAILED' -or $dbResult -like '*FAILED') { '部分失敗' }
    elseif ($dailyWarnings.Count -or $todoWarnings.Count -or $openWarnings.Count -or $dbResult -like '*WARNING') {
        '警告付き完了'
    }
    else { '完了' }

    $dailyDisplay = if ($dailyResult -eq 'OK' -and $dailyWarnings.Count) { '警告付き完了' } else { $dailyResult }
    $stageDisplay = @{
        OK = '完了'
        FAILED = '失敗'
        WARNING = '警告付き完了'
        'Skip (Daily failed)' = '省略（Daily 失敗）'
        'Skip (TODO failed)' = '省略（TODO 失敗）'
        'Skip (-SkipDb)' = '省略（-SkipDb）'
    }
    $dbDisplay = if ($stageDisplay.ContainsKey($dbResult)) { $stageDisplay[$dbResult] }
    else { $dbResult -replace ' OK$', ' 完了' -replace ' FAILED$', ' 失敗' -replace ' WARNING$', ' 警告付き完了' }
    $openDisplay = switch -Regex ($openResult) {
        '^Skip ' { '省略（-NoOpen）' }
        '^Requested (\d+) items?, (\d+) warnings?$' { "表示要求 $($Matches[1]) 件、警告 $($Matches[2]) 件" }
        '^Requested (\d+) items?$' { "表示要求 $($Matches[1]) 件" }
        '^0 items, 1 warning$' { '表示要求 0 件、警告 1 件' }
        default { '表示要求に失敗' }
    }
    if ($stageDisplay.ContainsKey($dailyDisplay)) { $dailyDisplay = $stageDisplay[$dailyDisplay] }

    Write-Host "mdstart $dateText | $overall"
    Write-Host "  Daily : $dailyDisplay"
    Write-Host "  TODO  : $($stageDisplay[$todoResult])"
    Write-Host "  DB    : $dbDisplay"
    Write-Host "  VS Code : $openDisplay"
}
