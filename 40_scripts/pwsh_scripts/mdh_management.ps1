<#
.SYNOPSIS
読み込まれているMDHの製品バージョンを表示します。
.DESCRIPTION
製品ルートの VERSION を読み取ります。
.PARAMETER Raw
製品名とバージョンを持つオブジェクトを返します。
.EXAMPLE
mdversion
#>
function mdversion {
    [CmdletBinding()]
    param([switch]$Raw)

    $path = Join-Path $script:MDHRoot 'VERSION'
    try {
        $text = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false, $true))
    }
    catch {
        $cause = $_.Exception.GetBaseException()
        if ($cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException]) {
            $PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new(
                $cause, 'MDH_VERSION_MISSING', 'ObjectNotFound', $path))
        }
        throw "VERSION を読み取れません: $($cause.Message)"
    }
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'VERSION が空です。' }
    # SemVer permits leading zeros only in non-numeric prerelease identifiers and build metadata.
    $number = '(?:0|[1-9][0-9]*)'
    $identifier = "(?:$number|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    $pattern = "\A$number\.$number\.$number(?:-$identifier(?:\.$identifier)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\r?\n)?\z"
    if ($text -cnotmatch $pattern) { throw 'VERSION の形式が不正です。' }
    $version = $text.TrimEnd([char]13, [char]10)
    if ($Raw) { [pscustomobject]@{ product = 'Markdown Daily Helper'; version = $version }; return }
    Write-Host "Markdown Daily Helper v$version"
}

function Get-MdhManagementPythonSettings {
    param([string]$Root)
    $db = $script:MDH_CONFIG.db
    if ($null -ne $db -and $db -isnot [pscustomobject] -and $db -isnot [Collections.IDictionary]) {
        throw 'config.db は JSON オブジェクトで指定してください。'
    }
    if ($null -ne $db.python -and $db.python -isnot [string]) {
        throw 'config.db.python は文字列で指定してください。'
    }
    @{ Root = $Root; Python = if ($db.python) { Get-MdhDbAbsolutePath -Root $Root -Value $db.python } }
}

function Get-MdhManagementConfig {
    param([string]$Root, [Collections.Generic.List[object]]$Diagnostics)

    $config = $script:MDH_CONFIG
    $result = [ordered]@{
        source = 'session'
        root = $Root
        config_path = Join-Path $Root '50_settings/config.json'
        daily = $config.paths.daily
        quicknotes = $config.paths.quicknotes
        aggregate = $config.paths.aggregate
        db_store = $null
        python = $null
        daily_template = $null
        update_links = $config.daily.update_links -ne $false
        update_schedule = $config.daily.update_schedule -ne $false
        todo_file = $null
        todo_routine_file = $null
        startup_open_files = @()
    }
    $resolve = [ordered]@{
        db_store = { Get-MdhDbStorePath -Root $Root -Db $config.db }
        python = {
            $settings = Get-MdhManagementPythonSettings -Root $Root
            if ($settings.Python) { [pscustomobject]@{ mode = 'configured'; path = $settings.Python } }
            else { [pscustomobject]@{ mode = 'auto'; path = $null } }
        }
        daily_template = { Get-MdhDailyTemplatePath }
        todo_file = { Get-MdhTodoPath }
        todo_routine_file = { Get-MdhTodoRoutinePath }
    }
    foreach ($field in $resolve.Keys) {
        try { $result[$field] = & $resolve[$field] }
        catch { $Diagnostics.Add([pscustomobject]@{ code = 'SETTING_FAILED'; field = $field; message = $_.Exception.Message }) }
    }
    $entries = $config.startup.open_files
    if ($null -ne $entries) {
        if ($entries -isnot [array] -or @($entries | Where-Object {
            $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_)
        }).Count) {
            $Diagnostics.Add([pscustomobject]@{ code = 'SETTING_FAILED'; field = 'startup_open_files'
                message = 'startup.open_files は空でない文字列の配列で指定してください。' })
        }
        elseif ($entries -is [array]) { $result.startup_open_files = $entries }
    }
    [pscustomobject]$result
}

function Write-MdhManagementList {
    param($Response)
    $result = $Response.result
    if ($null -eq $result) { return }
    switch ($Response.target) {
        'config' {
            foreach ($property in $result.PSObject.Properties) {
                $value = switch ($property.Name) {
                    'python' {
                        if ($property.Value.mode -eq 'auto') { '自動 (専用 venv / PATH)' }
                        else { $property.Value.path }
                    }
                    'startup_open_files' { $property.Value -join ', ' }
                    default { $property.Value }
                }
                Write-Host "$($property.Name) = $(ConvertTo-MdhManagementText $value)"
            }
        }
        'concept' {
            Write-Host "登録Concept: $($result.registered_count) 件"
            foreach ($item in $result.concepts) {
                $count = if ($item.PSObject.Properties['topic_count']) {
                    if ($null -eq $item.topic_count) { ' | 件数取得失敗' } else { " | $($item.topic_count) 件" }
                }
                Write-Host "$(ConvertTo-MdhManagementText $item.name) | Category: $(ConvertTo-MdhManagementText $item.category) | キーワード: $(ConvertTo-MdhManagementText ($item.keywords -join ', '))$count"
            }
        }
        'type' {
            Write-Host "対象Topic: $($result.total_topics) 件 (Daily Markdown)"
            foreach ($item in $result.types) {
                $name = if ($null -eq $item.key) { '未分類' } else { ConvertTo-MdhManagementText $item.name }
                Write-Host "$name | $($item.topic_count) 件"
            }
            if ($null -notin @($result.types.key)) { Write-Host '未分類 | 0 件' }
        }
    }
}

function ConvertTo-MdhManagementText {
    param([string]$Text)
    [regex]::Replace($Text, '[\p{Cc}\p{Cf}]', '?')
}

<#
.SYNOPSIS
有効設定、Concept、Typeを確認します。
.DESCRIPTION
設定はセッション、Conceptは設定ファイル、件数とTypeはDaily Markdownから読み取ります。
.PARAMETER Target
config、concept、typeから取得対象を指定します。既定はconfigです。
.PARAMETER Count
conceptの該当Topic件数を集計します。
.PARAMETER Raw
取得結果と診断を1件のオブジェクトとして返します。
.EXAMPLE
mdlist concept -Count -Raw
#>
function mdlist {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][ValidateSet('config', 'concept', 'type')][string]$Target = 'config',
        [switch]$Count,
        [switch]$Raw
    )
    $Target = $Target.ToLowerInvariant()
    if ($Count -and $Target -ne 'concept') { throw '-Count は concept 専用です。' }
    $diagnostics = [Collections.Generic.List[object]]::new()
    $result = $null
    $status = 'success'
    try {
        $root = $script:MDHRoot
        if (-not $root -or -not $script:MDH_CONFIG.paths) { throw 'MDH を読み込んでください。' }
        if ($Target -eq 'config') {
            $result = Get-MdhManagementConfig -Root $root -Diagnostics $diagnostics
            if ($diagnostics.Count) { $status = 'partial' }
        }
        else {
            $module = 'mdh_db.management_cli'
            $settings = Get-MdhManagementPythonSettings -Root $root
            $python = Resolve-MdhDbPython -Settings $settings -Module $module
            $argumentsToSend = @()
            if ($Target -eq 'concept') { $argumentsToSend += "--config=$(Join-Path $root '50_settings/config.json')" }
            if ($Target -eq 'type' -or $Count) { $argumentsToSend += "--daily-root=$($script:MDH_CONFIG.paths.daily)" }
            if ($Count) { $argumentsToSend += '--count' }
            $response = Invoke-MdhDbProcess -Python $python -Operation $Target -Arguments $argumentsToSend -Module $module
            $result = $response.result
            foreach ($item in $response.diagnostics) { $diagnostics.Add($item) }
            $status = switch ($response.exit_code) { 0 { 'success' } 1 { 'partial' } default { 'error' } }
        }
    }
    catch {
        $status = 'error'
        $diagnostics.Add([pscustomobject]@{ code = 'MANAGEMENT_FAILED'; message = $_.Exception.Message })
    }
    $answer = [pscustomobject]@{ contract_version = 1; target = $Target; status = $status
        result = $result; diagnostics = $diagnostics.ToArray() }
    if ($Raw) { return $answer }
    Write-MdhManagementList $answer
    $messages = ConvertTo-MdhManagementText ($answer.diagnostics.message -join ' / ')
    if ($status -eq 'partial') { Write-Warning $messages }
    elseif ($status -eq 'error') { Write-Error -Message $messages -ErrorId 'MDH_LIST_FAILED' }
}

<#
.SYNOPSIS
MDHのコマンド一覧または個別ヘルプを表示します。
.DESCRIPTION
各公開コマンドの標準Get-Helpを使用します。
.PARAMETER Command
公開コマンド名を指定します。省略時は一覧を表示します。
.PARAMETER Detailed
詳細なヘルプを表示します。
.PARAMETER Examples
使用例を表示します。
.PARAMETER Full
完全なヘルプを表示します。
.EXAMPLE
mdhelp mdsearch -Examples
#>
function mdhelp {
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    param(
        [Parameter(Position = 0)]
        [ArgumentCompleter({ param($commandName, $parameterName, $wordToComplete)
            Get-MdhPublicCommandNames | Where-Object { $_.StartsWith($wordToComplete, [StringComparison]::OrdinalIgnoreCase) }
        })][string]$Command,
        [Parameter(ParameterSetName = 'Detailed')][switch]$Detailed,
        [Parameter(ParameterSetName = 'Examples')][switch]$Examples,
        [Parameter(ParameterSetName = 'Full')][switch]$Full
    )
    $names = @(Get-MdhPublicCommandNames)
    if (-not $PSBoundParameters.ContainsKey('Command')) {
        if ($Detailed -or $Examples -or $Full) { throw '表示モードを指定する場合はコマンド名が必要です。' }
        $summaries = foreach ($name in $names) {
            $help = Get-MdhPublicCommandHelp $name
            '{0,-10} {1}' -f $name, $help.Synopsis.Trim()
        }
        Write-Host '===== MDH COMMANDS ====='
        foreach ($summary in $summaries) { Write-Host $summary }
        Write-Host 'Use: mdhelp <command> -Examples'
        return
    }
    if ($Command -notin $names) { throw 'MDHの公開コマンドではありません。その他のコマンドは Get-Help を使用してください。' }
    $help = Get-MdhPublicCommandHelp $Command
    if ($Detailed) { Get-Help -Name $Command -Detailed }
    elseif ($Examples) { Get-Help -Name $Command -Examples }
    elseif ($Full) { Get-Help -Name $Command -Full }
    else { $help }
}

function Get-MdhPublicCommandHelp {
    param([string]$Name)
    $null = Get-Command -Name $Name -CommandType Function -ErrorAction Stop
    $help = Get-Help -Name $Name -ErrorAction Stop
    if (-not $help.Synopsis -or $help.Synopsis -match ('^' + [regex]::Escape($Name) + '\s+\[')) {
        throw "公開コマンドのヘルプがありません: $Name"
    }
    return $help
}
