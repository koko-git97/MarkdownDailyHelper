# DB commands resolve configuration and Python only when invoked.

function Get-MdhDbAbsolutePath {
    param([string]$Value, [string]$Root)

    if ([IO.Path]::IsPathRooted($Value) -and -not [IO.Path]::IsPathFullyQualified($Value)) {
        throw "ドライブ相対・ルート相対のパスは指定できません: $Value"
    }
    return [IO.Path]::GetFullPath($Value, $Root)
}

function Get-MdhDbSettings {
    if (-not $script:MDHRoot -or -not $script:MDH_CONFIG.paths.daily) {
        throw 'MDH を読み込んでから DB コマンドを実行してください。'
    }
    $root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($script:MDHRoot))
    $db = $script:MDH_CONFIG.db
    if ($null -ne $db -and $db -isnot [pscustomobject] -and $db -isnot [System.Collections.IDictionary]) {
        throw 'config.db は JSON オブジェクトで指定してください。'
    }
    foreach ($value in @($db.store_dir, $db.python)) {
        if ($null -ne $value -and $value -isnot [string]) {
            throw 'config.db.store_dir と config.db.python は文字列で指定してください。'
        }
    }
    $store = if ([string]::IsNullOrWhiteSpace($db.store_dir)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -or
            -not [IO.Path]::IsPathFullyQualified($env:LOCALAPPDATA)) {
            throw 'LOCALAPPDATA が利用できません。config.db.store_dir を指定してください。'
        }
        $normalized = $root.Replace('/', '\').ToUpperInvariant()
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try { $hash = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)) }
        finally { $sha256.Dispose() }
        $identifier = [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
        Join-Path $env:LOCALAPPDATA ('MarkdownDailyHelper\db\' + $identifier)
    }
    else {
        Get-MdhDbAbsolutePath -Value $db.store_dir -Root $root
    }
    if ($store.StartsWith('\\')) {
        throw 'DB 保存先には Windows のローカルパスを指定してください。'
    }
    [pscustomobject]@{
        Root = $root
        Store = $store
        Daily = Get-MdhDbAbsolutePath -Value $script:MDH_CONFIG.paths.daily -Root $root
        Python = if ($db.python) { Get-MdhDbAbsolutePath -Value $db.python -Root $root }
    }
}

function New-MdhDbFailure {
    param([string]$Operation, [int]$Code, [string]$DiagnosticCode, [string]$Message)

    [pscustomobject]@{
        contract_version = 1
        operation = $Operation
        exit_code = $Code
        result = $null
        diagnostics = @([pscustomobject]@{ code = $DiagnosticCode; message = $Message })
    }
}

function Invoke-MdhDbProcess {
    param([string]$Python, [string]$Operation, [string[]]$Arguments = @(), [int]$Timeout = -1, [string]$Module = 'mdh_db')

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Python
    $start.WorkingDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'py_scripts'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($argument in @('-B', '-X', 'utf8', '-m', $Module, $Operation) + $Arguments) {
        $start.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($Timeout)) {
            $process.Kill()
            $process.WaitForExit()
            throw "Python の応答がありません: $Python"
        }
        $errorText = $stderr.GetAwaiter().GetResult().Trim()
        try {
            $jsonOptions = @{ Depth = 100; NoEnumerate = $true; ErrorAction = 'Stop' }
            if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
                $jsonOptions.DateKind = 'String'
            }
            $response = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json @jsonOptions
            if ($response -isnot [pscustomobject] -or
                $response.contract_version -ne 1 -or $response.operation -ne $Operation -or
                $null -eq $response.exit_code -or $response.exit_code -ne $process.ExitCode -or
                $response.exit_code -notin 0..6 -or
                -not $response.PSObject.Properties['result'] -or -not $response.PSObject.Properties['diagnostics']) {
                throw 'Python CLI の応答が JSON 契約と一致しません。'
            }
        }
        catch {
            throw "Python CLI の応答を解釈できません（終了コード $($process.ExitCode)）。$errorText $($_.Exception.Message)"
        }
        if ($errorText) { Write-Verbose $errorText }
        return $response
    }
    finally {
        $process.Dispose()
    }
}

function Resolve-MdhDbPython {
    param($Settings, [string]$Module = 'mdh_db', [switch]$SkipWindowsAppsAlias, [switch]$IncludeEnvironment)

    if ($Settings.Python) {
        $candidates = @($Settings.Python)
    }
    else {
        $candidates = @()
        $venv = Join-Path $Settings.Root '.venv\Scripts\python.exe'
        if (Test-Path -LiteralPath $venv -PathType Leaf) {
            $candidates += $venv
        }
        $candidates += @(Get-Command python.exe -All -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Source)
    }
    if (-not $candidates.Count) {
        throw 'Python が見つかりません。config.db.python、専用 venv、または PATH を確認してください。'
    }
    $failures = foreach ($candidate in $candidates | Select-Object -Unique) {
        if ($SkipWindowsAppsAlias -and $candidate -match '[\\/]Microsoft[\\/]WindowsApps[\\/]python\.exe$') {
            "$candidate : Microsoft Store の起動エイリアスを診断対象から除外しました。"
            continue
        }
        try {
            $probe = Invoke-MdhDbProcess -Python $candidate -Operation 'environment' -Timeout 10000 -Module $Module
            if ($probe.exit_code -eq 0) {
                if ($IncludeEnvironment) {
                    return [pscustomobject]@{ Path = $candidate; Environment = $probe.result }
                }
                return $candidate
            }
            "$candidate : $($probe.diagnostics.message -join '; ')"
        }
        catch {
            "$candidate : $($_.Exception.Message)"
        }
    }
    throw "利用できる Python 環境がありません。$($failures -join ' ')"
}

function Invoke-MdhDbCommand {
    param([string]$Operation, [string[]]$Arguments = @())

    try {
        $settings = Get-MdhDbSettings
    }
    catch {
        return New-MdhDbFailure $Operation 2 'INVALID_CONFIG' $_.Exception.Message
    }
    try {
        $python = Resolve-MdhDbPython -Settings $settings
    }
    catch {
        return New-MdhDbFailure $Operation 3 'PYTHON_ENVIRONMENT' $_.Exception.Message
    }

    $argumentsToSend = @("--store=$($settings.Store)", "--daily-root=$($settings.Daily)")
    try {
        return Invoke-MdhDbProcess -Python $python -Operation $Operation -Arguments ($argumentsToSend + $Arguments)
    }
    catch {
        $code = if ($Operation -eq 'rebuild') { 6 } else { 4 }
        return New-MdhDbFailure $Operation $code 'PYTHON_PROCESS_FAILED' $_.Exception.Message
    }
}

function Write-MdhDbResult {
    param($Response, [switch]$DisplayOnly)

    $global:LASTEXITCODE = [int]$Response.exit_code
    if ($Response.operation -in 'status', 'sync', 'rebuild') {
        $state = if ($Response.exit_code -ge 2) { '失敗' }
        elseif ($Response.exit_code -eq 1) { '部分成功または保留' }
        elseif ($Response.result.incomplete) { '警告付き完了' }
        else { '完了' }
        $counts = @(foreach ($field in @(
            @{ Name = 'indexed'; Label = '索引反映' }
            @{ Name = 'unchanged'; Label = '変更なし' }
            @{ Name = 'failed'; Label = '失敗' }
            @{ Name = 'missing'; Label = '不在' }
            @{ Name = 'deleted'; Label = '削除確定' }
        )) {
            if ($Response.result -and $Response.result.PSObject.Properties[$field.Name]) {
                "$($field.Label) $($Response.result.($field.Name)) 件"
            }
        })
        Write-Host ((@("md-db $($Response.operation)", "$state (終了コード $($Response.exit_code))") + $counts) -join ' | ')
        foreach ($diagnostic in $Response.diagnostics) {
            Write-Verbose "$($diagnostic.code) $($diagnostic.message)"
        }
    }
    if ($Response.exit_code -eq 1) {
        Write-Warning '同期が部分成功または保留になりました。結果と診断情報を確認してください。'
    }
    if ($Response.exit_code -eq 0 -and $Response.result.incomplete) {
        if ($Response.operation -eq 'status' -and -not $Response.result.initialized) {
            Write-Warning 'DB は未初期化です。初回構築には md-db -Rebuild を使用してください。'
        }
        else {
            Write-Warning '結果が不完全な可能性があります。除外件数と最終完全成功日時を確認してください。'
        }
    }
    if ($Response.result.stale_in_scope -gt 0) {
        Write-Warning '検索対象に旧スナップショットが含まれます。STALE の位置は現在の原文と異なる可能性があります。'
    }
    if ($Response.exit_code -ge 2) {
        if (-not $DisplayOnly) { Write-Output $Response }
        if ($Response.diagnostics.code -contains 'DAILY_ROOT_MISMATCH') {
            Write-Warning ($Response.diagnostics.message -join ' ')
            return
        }
        Write-Error -Message ($Response.diagnostics.message -join ' ') -ErrorId "MDH_DB_$($Response.exit_code)"
        return
    }
    if (-not $DisplayOnly) { Write-Output $Response }
}

<#
.SYNOPSIS
検索用DBの状態確認、同期、または再構築を行います。
.DESCRIPTION
既定は状態確認です。処理の構造化応答を返し、終了コードを LASTEXITCODE に設定します。
.PARAMETER Status
索引の初期化状態や完全性を確認します。
.PARAMETER Sync
日報の変更を索引に反映します。
.PARAMETER Rebuild
日報から索引を再構築します。
.PARAMETER ConfirmDeletions
Sync 時に削除を確認済みの日報を、Daily ルート相対パスで指定します。
.EXAMPLE
md-db -Status
.EXAMPLE
md-db -Sync -WhatIf
.NOTES
Sync と Rebuild は WhatIf と Confirm に対応します。終了コード 1 は部分成功または保留です。
#>
function md-db {
    [CmdletBinding(DefaultParameterSetName = 'Status', SupportsShouldProcess)]
    param(
        [Parameter(ParameterSetName = 'Status')]
        [switch]$Status,

        [Parameter(ParameterSetName = 'Sync', Mandatory)]
        [switch]$Sync,

        [Parameter(ParameterSetName = 'Rebuild', Mandatory)]
        [switch]$Rebuild,

        [Parameter(ParameterSetName = 'Sync')]
        [string[]]$ConfirmDeletions
    )

    if ($Rebuild) {
        if ($PSCmdlet.ShouldProcess('MDH データベース', '全件再構築')) {
            Write-MdhDbResult (Invoke-MdhDbCommand -Operation 'rebuild')
        }
        return
    }
    if ($Sync) {
        if ($PSCmdlet.ShouldProcess('MDH データベース', '増分同期')) {
            $arguments = @(foreach ($path in $ConfirmDeletions) { "--confirm-deletion=$path" })
            Write-MdhDbResult (Invoke-MdhDbCommand -Operation 'sync' -Arguments $arguments)
        }
        return
    }
    Write-MdhDbResult (Invoke-MdhDbCommand -Operation 'status')
}

function Format-MdhSearchLine {
    param([string]$Line, $Matches, [switch]$Highlight)

    if (-not $Highlight) { return $Line }
    # SQLite positions count Unicode code points while .NET indexes UTF-16.
    $characters = [regex]::Matches($Line, '[\uD800-\uDBFF][\uDC00-\uDFFF]|.')
    $cursor = 0
    $parts = foreach ($match in ($Matches | Sort-Object column, @{ Expression = { $_.excerpt.Length }; Descending = $true })) {
        $column = [int]$match.column - 1
        if ($column -lt 0 -or $column -ge $characters.Count) { continue }
        $start = $characters[$column].Index
        $length = $match.excerpt.Length
        if ($start -lt $cursor -or $length -eq 0 -or $start + $length -gt $Line.Length -or
            $Line.Substring($start, $length) -cne $match.excerpt) { continue }
        $Line.Substring($cursor, $start - $cursor)
        "$($PSStyle.Foreground.Yellow)$($match.excerpt)$($PSStyle.Reset)"
        $cursor = $start + $length
    }
    return ($parts -join '') + $Line.Substring($cursor)
}

function Write-MdhSearchList {
    param([string]$Query, $Result, [switch]$FullPath)

    $root = [IO.Path]::GetFullPath($script:MDHRoot)
    $dailyRoot = Get-MdhDbAbsolutePath -Value $script:MDH_CONFIG.paths.daily -Root $root
    $sourceLines = @{}
    $count = 0
    $highlight = $PSVersionTable.PSVersion -ge [version]'7.2' -and $Host.UI.SupportsVirtualTerminal -and
        $PSStyle.OutputRendering -ne 'PlainText' -and -not [Console]::IsOutputRedirected
    Write-Host "🔍 検索結果: $Query" -ForegroundColor Cyan

    foreach ($hit in $Result.hits) {
        $absolute = Get-MdhDbAbsolutePath -Value $hit.path -Root $dailyRoot
        $path = if ($FullPath) { $absolute } else { [IO.Path]::GetRelativePath($root, $absolute) }
        $snapshotNote = $null
        $lines = $null
        if ($hit.from_last_good_snapshot -or $hit.status -eq 'STALE') {
            $snapshotNote = '  ⚠ STALE・最後の正常スナップショット上の位置です。現在のファイル位置と一致する保証はありません。'
        }
        elseif (-not [IO.Path]::IsPathRooted($hit.path) -and ($hit.path -split '[/\\]') -notcontains '..') {
            $key = "$absolute|$($hit.snapshot_hash)"
            if (-not $sourceLines.ContainsKey($key)) {
                $sourceLines[$key] = $null
                # Context must come from the same bytes as the indexed position.
                try {
                    $source = Read-MdhTextFile -Path $absolute
                    if ($source.Hash -eq $hit.snapshot_hash) {
                        $sourceLines[$key] = $source.Content -split '\r\n|\r|\n'
                    }
                }
                catch {
                    # A missing or unreadable source still has an indexed match excerpt.
                }
            }
            $lines = $sourceLines[$key]
        }
        foreach ($line in ($hit.matches | Group-Object line)) {
            $lineNumber = $line.Group[0].line
            $count++
            $excerpt = ($line.Group.excerpt | Select-Object -Unique) -join ' / '
            $position = "L$lineNumber"
            $note = $snapshotNote
            if ($null -ne $lines -and $lineNumber -ge 1 -and $lineNumber -le $lines.Count) {
                $excerpt = Format-MdhSearchLine -Line $lines[$lineNumber - 1] -Matches $line.Group -Highlight:$highlight
            }
            else {
                $position = "索引 L$lineNumber"
                if (-not $note) {
                    $note = '  ⚠ 現在の原文位置を確認できません。行番号は索引作成時の位置です。'
                }
            }
            Write-Host ''
            Write-Host ('[{0}] {1} ({2})' -f $hit.day, $hit.title, $position) -ForegroundColor Green
            Write-Host ('  {0}' -f $excerpt)
            Write-Host "  🔗 $path" -ForegroundColor Cyan
            if ($note) { Write-Host $note -ForegroundColor Yellow }
        }
    }

    Write-Host ''
    if ($count -eq 0) { Write-Host '一致する日報はありませんでした。' }
    else { Write-Host "${count}件の一致" }
    if (-not $Result.incomplete) { return }
    $excluded = foreach ($property in $Result.excluded.PSObject.Properties) {
        '{0}={1}' -f $property.Name, $property.Value
    }
    $lastSuccess = if ($Result.last_full_success) { $Result.last_full_success } else { '未記録' }
    Write-Host ('完全性: 不完全の可能性あり | 除外 {0} | 日付不明INVALID {1} | 最終完全成功 {2}' -f
        ($excluded -join ', '), $Result.undated_invalid, $lastSuccess) -ForegroundColor Yellow
}

<#
.SYNOPSIS
索引から日報を検索します。
.DESCRIPTION
検索語の部分一致を表示します。空白区切りの複数語は AND です。
.PARAMETER Query
検索語を指定します。
.PARAMETER From
検索開始日を yyyy-MM-dd で指定します。当日を含みます。
.PARAMETER To
検索終了日を yyyy-MM-dd で指定します。当日を含みます。
.PARAMETER IncludeStale
STALE の最後の正常スナップショットも検索します。
.PARAMETER List
通常と同じ検索結果一覧を表示します。
.PARAMETER FullPath
一覧のファイルパスを絶対パスで表示します。
.PARAMETER Raw
一覧表示を省略し、構造化応答を返します。
.PARAMETER DebugInfo
JSON 応答の詳細を情報ストリームに表示します。
.EXAMPLE
mdsearch '図書 CSV' -Raw
.NOTES
索引の位置は現在の原文と異なる場合があります。
#>
function mdsearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Query,

        [string]$From,
        [string]$To,
        [switch]$IncludeStale,
        [switch]$List,
        [switch]$FullPath,
        [switch]$Raw,
        [switch]$DebugInfo
    )

    $arguments = @("--query=$Query")
    if ($PSBoundParameters.ContainsKey('From')) { $arguments += "--from=$From" }
    if ($PSBoundParameters.ContainsKey('To')) { $arguments += "--to=$To" }
    if ($IncludeStale) { $arguments += '--include-stale' }
    $response = Invoke-MdhDbCommand -Operation 'search' -Arguments $arguments
    if (-not $Raw -and $response.exit_code -eq 0) {
        Write-MdhSearchList -Query $Query -Result $response.result -FullPath:$FullPath
    }
    if ($DebugInfo) {
        Write-Host '検索の詳細' -ForegroundColor Cyan
        Write-Host ($response | ConvertTo-Json -Depth 100)
    }
    if (-not $Raw -and $response.exit_code -ge 2) {
        Write-Host 'mdsearch | 検索に失敗しました。診断を確認し、索引の状態は md-db -Status で確認できます。'
    }
    Write-MdhDbResult $response -DisplayOnly:(-not $Raw)
}
