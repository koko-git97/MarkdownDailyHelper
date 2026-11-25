# DB commands resolve configuration and Python only when invoked.

function Get-MdhDbAbsolutePath {
    param([string]$Value, [string]$Root)

    if ([IO.Path]::IsPathRooted($Value) -and -not [IO.Path]::IsPathFullyQualified($Value)) {
        throw "ドライブ相対・ルート相対のパスは指定できません: $Value"
    }
    return [IO.Path]::GetFullPath($Value, $Root)
}

function Get-MdhDbStorePath {
    param([string]$Root, $Db)

    $root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Root))
    if ($null -ne $Db -and $Db -isnot [pscustomobject] -and $Db -isnot [System.Collections.IDictionary]) {
        throw 'config.db は JSON オブジェクトで指定してください。'
    }
    if ($null -ne $Db.store_dir -and $Db.store_dir -isnot [string]) {
        throw 'config.db.store_dir は文字列で指定してください。'
    }
    $store = if ([string]::IsNullOrWhiteSpace($Db.store_dir)) {
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
        Get-MdhDbAbsolutePath -Value $Db.store_dir -Root $root
    }
    if ($store.StartsWith('\\')) {
        throw 'DB 保存先には Windows のローカルパスを指定してください。'
    }
    return $store
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
    $store = Get-MdhDbStorePath -Root $root -Db $db
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
    param($Response, [switch]$DisplayOnly, [switch]$SafeSearchText)

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
        $message = $Response.diagnostics.message -join ' '
        if ($SafeSearchText) { $message = ConvertTo-MdhSafeSearchText $message }
        if ($Response.diagnostics.code -contains 'DAILY_ROOT_MISMATCH') {
            Write-Warning $message
            return
        }
        Write-Error -Message $message -ErrorId "MDH_DB_$($Response.exit_code)"
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

function ConvertTo-MdhSafeSearchText {
    param([string]$Text)

    [regex]::Replace($Text, '[\p{Cc}\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]', {
        param($control)
        '\u{0:X4}' -f [int][char]$control.Value
    })
}

function Test-MdhSearchColor {
    $Host.UI.SupportsVirtualTerminal -and -not [Console]::IsOutputRedirected -and
        -not (Test-Path Env:NO_COLOR) -and
        ($PSVersionTable.PSVersion -lt [version]'7.2' -or $PSStyle.OutputRendering -ne 'PlainText')
}

function Write-MdhSearchHeader {
    param([string]$Text, [ConsoleColor]$Color)
    if (Test-MdhSearchColor) { Write-Host $Text -ForegroundColor $Color }
    else { Write-Host $Text }
}

function Format-MdhSearchLine {
    param([string]$Line, $Matches, [switch]$Highlight)

    if (-not $Highlight) { return ConvertTo-MdhSafeSearchText $Line }
    # SQLite positions count Unicode code points while .NET indexes UTF-16.
    $characters = [regex]::Matches($Line, '[\uD800-\uDBFF][\uDC00-\uDFFF]|.')
    $ranges = [Collections.Generic.List[object]]::new()
    $terms = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($hit in $Matches) {
        $column = [int]$hit.column - 1
        $excerpt = [string]$hit.excerpt
        if ($column -lt 0 -or $column -ge $characters.Count -or -not $excerpt.Length) { continue }
        $start = $characters[$column].Index
        if ($start + $excerpt.Length -gt $Line.Length -or
            $Line.Substring($start, $excerpt.Length) -cne $excerpt) { continue }
        $ranges.Add(@{ Start = $start; Stop = $start + $excerpt.Length })
        if ($hit.term) { $null = $terms.Add([string]$hit.term) }
    }
    if ($terms.Count) {
        # Unlike Unicode case folding, SQLite LIKE folds only ASCII A-Z.
        $fold = { param($m) $m.Value.ToLowerInvariant() }
        $folded = [regex]::Replace($Line, '[A-Z]', $fold)
        foreach ($term in $terms) {
            $needle = [regex]::Replace($term, '[A-Z]', $fold)
            for ($start = $folded.IndexOf($needle, [StringComparison]::Ordinal); $start -ge 0;
                $start = $folded.IndexOf($needle, $start + 1, [StringComparison]::Ordinal)) {
                $ranges.Add(@{ Start = $start; Stop = $start + $needle.Length })
            }
        }
    }
    $merged = [Collections.Generic.List[object]]::new()
    foreach ($range in ($ranges | Sort-Object { $_.Start })) {
        if ($merged.Count -and $range.Start -le $merged[$merged.Count - 1].Stop) {
            $previous = $merged[$merged.Count - 1]
            $previous.Stop = [Math]::Max($previous.Stop, $range.Stop)
        }
        else { $merged.Add($range) }
    }
    $cursor = 0
    $escape = [char]27
    $parts = foreach ($range in $merged) {
        ConvertTo-MdhSafeSearchText $Line.Substring($cursor, $range.Start - $cursor)
        "$escape[33m$(ConvertTo-MdhSafeSearchText $Line.Substring($range.Start, $range.Stop - $range.Start))$escape[0m"
        $cursor = $range.Stop
    }
    return ($parts -join '') + (ConvertTo-MdhSafeSearchText $Line.Substring($cursor))
}

function Get-MdhSearchDisplayPath {
    param([string]$Path, [string]$Root, [switch]$FullPath)

    if ($FullPath) { return $Path }
    $relative = [IO.Path]::GetRelativePath($Root, $Path)
    if ([IO.Path]::IsPathRooted($relative) -or ($relative -split '[/\\]') -contains '..') { return $Path }
    return $relative
}

function Write-MdhSearchRows {
    param($Rows, $Lines, [hashtable]$SnapshotLines, [switch]$Highlight)

    foreach ($row in $Rows) {
        $number = [int]$row.Name
        if ($null -ne $SnapshotLines -and $SnapshotLines.ContainsKey($number)) {
            $text = Format-MdhSearchLine -Line $SnapshotLines[$number] -Matches $row.Group -Highlight:$Highlight
            Write-Host "  L$number | $text"
        }
        elseif ($null -ne $Lines -and $number -ge 1 -and $number -le $Lines.Count) {
            $text = Format-MdhSearchLine -Line $Lines[$number - 1] -Matches $row.Group -Highlight:$Highlight
            Write-Host "  L$number | $text"
        }
        else {
            $text = ConvertTo-MdhSafeSearchText (($row.Group.excerpt | Select-Object -Unique) -join ' / ')
            Write-Host "  索引 L$number | $text"
        }
    }
}

function Get-MdhSearchGroups {
    param($Hits)

    foreach ($hit in $Hits) {
        [pscustomobject]@{ Hit = $hit; Rows = @($hit.matches | Group-Object line | Sort-Object { [int]$_.Name }) }
    }
}

function Write-MdhSearchList {
    param([string]$Query, $Result, [switch]$FullPath, [switch]$HideQuery, $Groups)

    $root = [IO.Path]::GetFullPath($script:MDHRoot)
    $dailyRoot = Get-MdhDbAbsolutePath -Value $script:MDH_CONFIG.paths.daily -Root $root
    $sourceLines = @{}
    $highlight = Test-MdhSearchColor
    $hits = @($Result.hits)
    $topics = @($hits | Where-Object kind -eq 'topic').Count
    if ($null -eq $Groups) { $Groups = @(Get-MdhSearchGroups $hits) }
    $count = 0
    foreach ($group in $groups) { $count += $group.Rows.Count }
    if (-not $HideQuery) { Write-MdhSearchHeader "検索結果: $(ConvertTo-MdhSafeSearchText $Query)" Cyan }
    Write-MdhSearchHeader '===== DAILY =====' Cyan
    $groupLabel = if ($hits.Count -eq $topics) { "$topics Topics" } else { "$($hits.Count) Groups ($topics Topics)" }
    Write-Host "$groupLabel / $count matching lines"

    foreach ($group in $groups) {
        $hit = $group.Hit
        $path = $hit.path
        $snapshotNote = $null
        $lines = $null
        $stale = $hit.from_last_good_snapshot -or $hit.status -eq 'STALE'
        if ($stale) {
            $snapshotNote = '  ⚠ STALE・最後の正常スナップショット上の位置です。現在のファイル位置と一致する保証はありません。'
        }
        if (-not [IO.Path]::IsPathRooted($hit.path) -and ($hit.path -split '[/\\]') -notcontains '..') {
            $absolute = Get-MdhDbAbsolutePath -Value $hit.path -Root $dailyRoot
            $path = Get-MdhSearchDisplayPath -Path $absolute -Root $root -FullPath:$FullPath
            if (-not $stale) {
                $key = "$absolute|$($hit.snapshot_hash)"
                if (-not $sourceLines.ContainsKey($key)) {
                    $sourceLines[$key] = $null
                    try {
                        $source = Read-MdhTextFile -Path $absolute
                        if ($source.Hash -eq $hit.snapshot_hash) {
                            $sourceLines[$key] = $source.Content -split '\r\n|\r|\n'
                        }
                    }
                    catch {
                        # A missing or unreadable source still has indexed excerpts.
                    }
                }
                $lines = $sourceLines[$key]
            }
        }
        if (-not $snapshotNote -and ($null -eq $lines -or
            @($group.Rows | Where-Object { [int]$_.Name -lt 1 -or [int]$_.Name -gt $lines.Count }).Count)) {
            $snapshotNote = '  ⚠ 現在の原文位置を確認できません。行番号は索引作成時の位置です。'
        }
        $kind = switch ($hit.kind) {
            'topic' { 'Topic' }
            'preamble' { '前文' }
            'completion' { '完了記録' }
            default { '日報セクション' }
        }
        $title = if ($hit.title -and $hit.kind -ne 'topic') { "[$kind] $($hit.title)" }
        elseif ($hit.title) { $hit.title }
        else { $kind }
        Write-Host ''
        Write-MdhSearchHeader "$(ConvertTo-MdhSafeSearchText $hit.day) | $(ConvertTo-MdhSafeSearchText $title)" Cyan
        Write-Host (ConvertTo-MdhSafeSearchText $path)
        Write-MdhSearchRows -Rows $group.Rows -Lines $lines -Highlight:$highlight
        if ($snapshotNote) { Write-Host $snapshotNote }
    }

    if ($count -eq 0) { Write-Host '一致する日報はありませんでした。' }
    if (-not $Result.incomplete) { return }
    $excluded = foreach ($property in $Result.excluded.PSObject.Properties) {
        '{0}={1}' -f $property.Name, $property.Value
    }
    $lastSuccess = if ($Result.last_full_success) { $Result.last_full_success } else { '未記録' }
    $coverage = '完全性: 不完全の可能性あり | 除外 {0} | 日付不明INVALID {1} | 最終完全成功 {2}' -f
        ($excluded -join ', '), $Result.undated_invalid, $lastSuccess
    Write-Host (ConvertTo-MdhSafeSearchText $coverage)
}

function Invoke-MdhQuickNotesSearch {
    param([string]$Query)

    try {
        if (-not $script:MDHRoot -or -not $script:MDH_CONFIG.paths.quicknotes) {
            throw 'MDH の QuickNotes 保存先が初期化されていません。'
        }
        $root = Get-MdhDbAbsolutePath -Value $script:MDH_CONFIG.paths.quicknotes -Root $script:MDHRoot
        $pythonPath = $script:MDH_CONFIG.db.python
        if ($null -ne $pythonPath -and $pythonPath -isnot [string]) {
            throw 'config.db.python は文字列で指定してください。'
        }
        $settings = @{ Root = $script:MDHRoot; Python = if ($pythonPath) {
            Get-MdhDbAbsolutePath -Value $pythonPath -Root $script:MDHRoot
        } }
    }
    catch { return New-MdhDbFailure 'quicknotes' 2 'INVALID_CONFIG' $_.Exception.Message }
    try { $python = Resolve-MdhDbPython -Settings $settings }
    catch { return New-MdhDbFailure 'quicknotes' 3 'PYTHON_ENVIRONMENT' $_.Exception.Message }
    try {
        Invoke-MdhDbProcess -Python $python -Operation 'quicknotes' -Arguments @("--root=$root", "--query=$Query")
    }
    catch { return New-MdhDbFailure 'quicknotes' 4 'PYTHON_PROCESS_FAILED' $_.Exception.Message }
}

function Write-MdhQuickNotesSearchList {
    param($Result, [switch]$FullPath)

    $root = [IO.Path]::GetFullPath($script:MDHRoot)
    $quicknotesRoot = Get-MdhDbAbsolutePath -Value $script:MDH_CONFIG.paths.quicknotes -Root $root
    $highlight = Test-MdhSearchColor
    Write-Host "$($Result.files_matched) Files / $($Result.matching_lines) matching lines"
    foreach ($group in (Get-MdhSearchGroups $Result.hits)) {
        $hit = $group.Hit
        $absolute = Get-MdhDbAbsolutePath -Value $hit.path -Root $quicknotesRoot
        $path = Get-MdhSearchDisplayPath -Path $absolute -Root $root -FullPath:$FullPath
        $snapshot = @{}
        foreach ($line in $hit.lines) { $snapshot[[int]$line.line] = [string]$line.text }
        Write-Host ''
        Write-MdhSearchHeader (ConvertTo-MdhSafeSearchText $hit.title) Magenta
        Write-Host (ConvertTo-MdhSafeSearchText $path)
        Write-MdhSearchRows -Rows $group.Rows -SnapshotLines $snapshot -Highlight:$highlight
    }
    foreach ($diagnostic in $Result.diagnostics) {
        $detail = '{0} | {1} | {2}' -f $diagnostic.code, $diagnostic.path, $diagnostic.message
        Write-Host (ConvertTo-MdhSafeSearchText $detail)
    }
}

function Write-MdhSearchDebug {
    param($Response)

    Write-MdhSearchHeader '検索の詳細' Cyan
    foreach ($line in (($Response | ConvertTo-Json -Depth 100) -split '\r?\n')) {
        Write-Host (ConvertTo-MdhSafeSearchText $line)
    }
}

function Invoke-MdhExtendedSearch {
    param($Options, [string[]]$Arguments)

    $scope = $Options.Scope
    $query = $Options.Query
    $response = [pscustomobject]@{
        search_contract_version = 1; scope = $scope; query = $query; status = 'error'
        exit_code = 2; sources = [pscustomobject]@{}; diagnostics = @()
    }
    $errorMessage = if ($query.Contains([char]0)) { '検索語に NUL は使用できません。' }
    elseif ($scope -eq 'QuickNotes' -and
        ($Options.ContainsKey('From') -or $Options.ContainsKey('To') -or $Options.ContainsKey('IncludeStale'))) {
        'QuickNotes では -From、-To、-IncludeStale を指定できません。'
    }
    else {
        foreach ($bound in 'From', 'To') {
            if (-not $Options.ContainsKey($bound)) { continue }
            $parsed = [datetime]::MinValue
            if ($Options[$bound] -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}\z' -or
                -not [datetime]::TryParseExact($Options[$bound], 'yyyy-MM-dd',
                    [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                "検索日付 -$bound は有効な yyyy-MM-dd で指定してください。"
                break
            }
        }
        if ($Options.From -and $Options.To -and $Options.From -gt $Options.To) {
            '開始日は終了日以前を指定してください。'
        }
    }

    if ($errorMessage) {
        $response.diagnostics = @([pscustomobject]@{ code = 'INVALID_ARGUMENT'; message = $errorMessage -join ' ' })
    }
    else {
        $daily = if ($scope -eq 'All') { Invoke-MdhDbCommand -Operation 'search' -Arguments $Arguments }
        $quicknotes = Invoke-MdhQuickNotesSearch -Query $query
        $quickStatus = if ($quicknotes.exit_code -eq 0) { 'success' } else { 'error' }
        $sources = [ordered]@{}
        if ($scope -eq 'All') {
            $dailyStatus = if ($daily.exit_code -eq 0) { 'success' } else { 'error' }
            $sources.daily = [pscustomobject]@{
                status = $dailyStatus; response = $daily
                filters = [pscustomobject]@{ from = $Options.From; to = $Options.To; include_stale = [bool]$Options.IncludeStale }
            }
        }
        $sources.quicknotes = [pscustomobject]@{
            status = $quickStatus; exit_code = $quicknotes.exit_code
            result = $quicknotes.result; diagnostics = $quicknotes.diagnostics
        }
        $response.sources = [pscustomobject]$sources
        $successes = @($sources.Values | Where-Object status -eq 'success').Count
        if ($successes -eq $sources.Count) { $response.status = 'success'; $response.exit_code = 0 }
        elseif ($successes) { $response.status = 'partial'; $response.exit_code = 1 }
        else { $response.exit_code = 4 }

        if (-not $Options.Raw) {
            Write-MdhSearchHeader "検索結果: $(ConvertTo-MdhSafeSearchText $query)" Cyan
            if ($scope -eq 'All') {
                $groups = @(Get-MdhSearchGroups $daily.result.hits)
                $lines = [int]$quicknotes.result.matching_lines
                foreach ($group in $groups) { $lines += $group.Rows.Count }
                $count = $groups.Count + [int]$quicknotes.result.files_matched
                $totals = if ($response.status -eq 'success') { '' } else { '（成功した検索元のみ）' }
                if ($successes) { Write-Host "$count Groups / $lines matching lines$totals" }
                Write-Host ''
                if ($dailyStatus -eq 'success') {
                    Write-MdhSearchList -Query $query -Result $daily.result -FullPath:$Options.FullPath -HideQuery -Groups $groups
                }
                else {
                    Write-MdhSearchHeader '===== DAILY =====' Cyan
                    Write-Host "検索失敗: $(ConvertTo-MdhSafeSearchText ($daily.diagnostics.message -join ' '))"
                }
                Write-Host ''
            }
            Write-MdhSearchHeader '===== QUICKNOTES =====' Magenta
            if ($scope -eq 'All' -and ($Options.From -or $Options.To)) { Write-Host 'QuickNotesには日付制限を適用しません。' }
            if ($quickStatus -eq 'success') {
                Write-MdhQuickNotesSearchList -Result $quicknotes.result -FullPath:$Options.FullPath
            }
            else {
                Write-Host "検索失敗: $(ConvertTo-MdhSafeSearchText ($quicknotes.diagnostics.message -join ' '))"
            }
            if ($response.status -eq 'partial') { Write-Host '検索状態: 部分失敗。成功した検索元の結果を表示しています。' }
        }
    }

    $global:LASTEXITCODE = $response.exit_code
    if ($Options.Raw) { Write-Output $response }
    if ($Options.DebugInfo) { Write-MdhSearchDebug $response }
    if ($response.sources.daily.response.result.incomplete -or $response.sources.quicknotes.result.incomplete) {
        Write-Warning '検索結果が不完全です。各検索元の状態と診断を確認してください。'
    }
    if ($response.status -ne 'success') {
        $summary = if ($response.diagnostics.Count) { $response.diagnostics[0].message }
        elseif ($response.status -eq 'partial') { '検索が部分失敗しました。' }
        else { '検索に失敗しました。' }
        Write-Error -Message $summary -ErrorId "MDH_SEARCH_$($response.exit_code)"
    }
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
.PARAMETER Scope
検索元として Daily、QuickNotes、All を指定します。既定は Daily です。
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
        [switch]$DebugInfo,
        [ValidateSet('Daily', 'QuickNotes', 'All')]
        [string]$Scope = 'Daily'
    )

    $arguments = @("--query=$Query")
    if ($PSBoundParameters.ContainsKey('From')) { $arguments += "--from=$From" }
    if ($PSBoundParameters.ContainsKey('To')) { $arguments += "--to=$To" }
    if ($IncludeStale) { $arguments += '--include-stale' }
    if ($Scope -ne 'Daily') {
        # Validation is case-insensitive, but the response uses canonical scope names.
        $options = @{} + $PSBoundParameters
        $options.Scope = if ($Scope -eq 'All') { 'All' } else { 'QuickNotes' }
        Invoke-MdhExtendedSearch -Options $options -Arguments $arguments
        return
    }
    $response = Invoke-MdhDbCommand -Operation 'search' -Arguments $arguments
    if (-not $Raw -and $response.exit_code -eq 0) {
        Write-MdhSearchList -Query $Query -Result $response.result -FullPath:$FullPath
    }
    if ($DebugInfo) {
        Write-MdhSearchDebug $response
    }
    if (-not $Raw -and $response.exit_code -ge 2) {
        Write-Host 'mdsearch | 検索に失敗しました。診断を確認し、索引の状態は md-db -Status で確認できます。'
    }
    Write-MdhDbResult $response -DisplayOnly:(-not $Raw) -SafeSearchText:(-not $Raw)
}
