$repository = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

Describe 'MDH management commands' {
    BeforeEach {
        $root = Join-Path $TestDrive ("MDH 日本語 " + [guid]::NewGuid())
        $scripts = Join-Path $root '40_scripts/pwsh_scripts'
        $settings = Join-Path $root '50_settings'
        $null = [IO.Directory]::CreateDirectory($scripts)
        $null = [IO.Directory]::CreateDirectory($settings)
        Copy-Item (Join-Path $repository '40_scripts/pwsh_scripts/mdh*.ps1') -Destination $scripts
        Copy-Item (Join-Path $repository 'VERSION') -Destination $root
        $configPath = Join-Path $settings 'config.json'
        $configuration = @{
            paths = @{ daily = '日報'; quicknotes = 'メモ' }
            daily = @{ template = 'templates/Daily.md'; update_schedule = $false }
            todo = @{ file = '{quicknotes}/tasks.md' }
            db = @{ store_dir = '\\server\share'; python = $env:MDH_TEST_PYTHON_EXECUTABLE }
            startup = @{ open_files = @('{todo}', '{previous_daily}') }
            concepts = @{ Alpha = @{ category = 'Work'; keywords = @('other') } }
            ignored = 'UNLISTED_FIXTURE'
        }
        $configuration | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath
        . (Join-Path $scripts 'mdh.ps1')
    }

    It 'reads valid and invalid VERSION from the loaded root without using PATH' {
        $versionPath = Join-Path $root 'VERSION'
        $oldPath = $env:PATH
        try {
            $env:PATH = ''
            Push-Location -LiteralPath $TestDrive
            foreach ($value in '2.2.0-dev', '2.2.0', '2.2.0-rc.1+fixture.001') {
                [IO.File]::WriteAllText($versionPath, $value + [Environment]::NewLine)
                $result = @(mdversion -Raw)
                $result.Count | Should Be 1
                $result[0].product | Should Be 'Markdown Daily Helper'
                $result[0].version | Should Be $value
                (mdversion 6>&1 | Out-String) | Should Match ([regex]::Escape("Markdown Daily Helper v$value"))
            }
            foreach ($value in '', '2.02.0', '2.2.0-01', "2.2.0$([Environment]::NewLine)2.2.1") {
                [IO.File]::WriteAllText($versionPath, $value)
                { mdversion -Raw } | Should Throw 'VERSION'
            }
            $lock = [IO.File]::Open($versionPath, 'Open', 'ReadWrite', 'None')
            try { { mdversion -Raw } | Should Throw '読み取れません' }
            finally { $lock.Dispose() }
            Remove-Item -LiteralPath $versionPath
            { mdversion -Raw } | Should Throw 'VERSION'
        }
        finally { Pop-Location; $env:PATH = $oldPath }
    }

    It 'shows session settings with stable arrays and preserves unrelated values on a settings error' {
        $snapshot = Get-FileHash -LiteralPath $configPath
        $answer = @(mdlist -Raw -ErrorAction Stop)
        $answer.Count | Should Be 1
        $answer[0].status | Should Be 'partial'
        $answer[0].diagnostics[0].field | Should Be 'db_store'
        $answer[0].result.config_path | Should Be $configPath
        $answer[0].result.daily | Should Be (Join-Path $root '日報')
        $answer[0].result.todo_file | Should Be (Join-Path $root 'メモ/tasks.md')
        $answer[0].result.update_schedule | Should Be $false
        $answer[0].result.startup_open_files[1] | Should Be '{previous_daily}'
        $json = $answer[0] | ConvertTo-Json -Depth 10 -Compress
        $json | Should Not Match 'UNLISTED_FIXTURE'
        $json | Should Be (mdlist config -Raw | ConvertTo-Json -Depth 10 -Compress)
        (Get-FileHash -LiteralPath $configPath).Hash | Should Be $snapshot.Hash
        $configuration.paths.daily = 'edited'
        $configuration | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath
        (mdlist config -Raw).result.daily | Should Be (Join-Path $root '日報')
        Test-Path -LiteralPath (Join-Path $root 'edited') | Should Be $false
        $script:MDH_CONFIG.db.store_dir = 'store'
        $script:MDH_CONFIG.db.python = 'missing.exe'
        (mdlist -Raw).status | Should Be 'success'
        (mdlist -Raw).result.db_store | Should Be (Join-Path $root 'store')
        Test-Path -LiteralPath (Join-Path $root 'store') | Should Be $false
        $script:MDH_CONFIG.startup.open_files = @()
        $result = (mdlist -Raw).result
        ($result.startup_open_files -is [array]) | Should Be $true
        $result.startup_open_files.Count | Should Be 0
    }

    It 'uses the Python CLI without depending on DB paths and keeps Raw on partial or total failures' -Skip:(-not $env:MDH_TEST_PYTHON_EXECUTABLE) {
        Copy-Item (Join-Path $repository '40_scripts/py_scripts') -Destination (Join-Path $root '40_scripts') -Recurse
        $dailyRoot = Join-Path $root '日報'
        $source = Join-Path $dailyRoot '2026/2026-11/2026-11-23.md'
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $source))
        [IO.File]::WriteAllText($source, "# ✅ やったこと$([Environment]::NewLine)## [Meeting] Alpha")
        $hash = (Get-FileHash -LiteralPath $source).Hash
        $concept = @(mdlist -Target concept -Count -Raw -ErrorAction Stop)
        $concept.Count | Should Be 1
        $concept[0].status | Should Be 'success'
        $concept[0].result.concepts[0].topic_count | Should Be 1
        ((mdlist concept -Raw).result.concepts -is [array]) | Should Be $true
        ((mdlist concept -Raw).result.concepts[0].keywords -is [array]) | Should Be $true
        (mdlist type -Raw).result.types[0].key | Should Be 'meeting'
        (mdlist type 6>&1 | Out-String) | Should Match '未分類.*0 件'
        (Get-FileHash -LiteralPath $source).Hash | Should Be $hash
        @(Get-ChildItem -LiteralPath (Join-Path $root '10_Aggregate')).Count | Should Be 0
        $script:MDH_CONFIG.paths.daily = Join-Path $root 'missing'
        (mdlist concept -Raw).status | Should Be 'success'
        $partial = @(mdlist concept -Count -Raw -ErrorAction Stop)
        $partial.Count | Should Be 1
        $partial[0].status | Should Be 'partial'
        $partial[0].result.concepts[0].topic_count | Should Be $null
        $failure = @(mdlist type -Raw -ErrorAction Stop)
        $failure.Count | Should Be 1
        $failure[0].status | Should Be 'error'
        $failure[0].diagnostics[0].code | Should Be 'DAILY_FAILED'
        $script:MDH_CONFIG.db.python = 'missing.exe'
        (mdlist concept -Raw -ErrorAction Stop).status | Should Be 'error'
        { mdlist config -Count -Raw -ErrorAction Stop } | Should Throw 'concept'
        { mdlist type -Count -Raw -ErrorAction Stop } | Should Throw 'concept'
        { mdlist unknown -Raw -ErrorAction Stop } | Should Throw 'unknown'
    }

    It 'reports non-Raw outcomes through information, warning and error streams' {
        Mock Resolve-MdhDbPython { 'fixture-python' }
        Mock Invoke-MdhDbProcess {
            if ($Operation -eq 'type') {
                return (New-MdhDbFailure -Operation type -Code 4 -DiagnosticCode DAILY_FAILED -Message 'fixture failure')
            }
            $partial = '--count' -in $Arguments
            [pscustomobject]@{
                exit_code = if ($partial) { 1 } else { 0 }
                result = [pscustomobject]@{ registered_count = 0; concepts = @() }
                diagnostics = @(if ($partial) { [pscustomobject]@{ code = 'DAILY_FAILED'; message = 'fixture failure' } })
            }
        }
        $parameters = (Get-Command mdlist).ScriptBlock.Ast.Body.ParamBlock.Parameters
        (($parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) -join ',') | Should Be 'Target,Count,Raw'

        $success = @(mdlist concept -ErrorAction Stop 6>&1 3>&1 2>&1)
        $success.Count | Should Be 1
        ($success[0] -is [Management.Automation.InformationRecord]) | Should Be $true
        $success[0].MessageData | Should Match '登録Concept'
        $partial = @(mdlist concept -Count -ErrorAction Stop 6>&1 3>&1 2>&1)
        $partial.Count | Should Be 2
        ($partial[0] -is [Management.Automation.InformationRecord]) | Should Be $true
        ($partial[1] -is [Management.Automation.WarningRecord]) | Should Be $true
        $partial[1].Message | Should Be 'fixture failure'
        $errorOutput = @(mdlist type -ErrorAction Continue 6>&1 3>&1 2>&1)
        $errorOutput.Count | Should Be 1
        ($errorOutput[0] -is [Management.Automation.ErrorRecord]) | Should Be $true
        $errorOutput[0].FullyQualifiedErrorId | Should Match '^MDH_LIST_FAILED'
        { mdlist type -ErrorAction Stop } | Should Throw 'fixture failure'
        $raw = @(mdlist type -Raw -ErrorAction Stop 6>&1 3>&1 2>&1)
        $raw.Count | Should Be 1
        $raw[0].status | Should Be 'error'
        $raw[0].diagnostics[0].code | Should Be 'DAILY_FAILED'
    }

    It 'lists only the documented public commands and delegates help and completion' {
        $names = 'mdstart', 'daily', 'mdtoday', 'todo', 'quicklinks', 'md-db', 'mdsearch', 'mdreverse', 'mdrun', 'mdversion', 'mdlist', 'mdhelp'
        $list = mdhelp 6>&1 | Out-String
        foreach ($name in $names) {
            $list | Should Match ([regex]::Escape($name))
            $list | Should Match ([regex]::Escape((Get-Help $name).Synopsis.Trim()))
        }
        foreach ($mode in 'Detailed', 'Examples', 'Full') {
            $options = @{ $mode = $true }
            (mdhelp mdsearch @options | Out-String) | Should Be (Get-Help mdsearch @options | Out-String)
        }
        foreach ($name in 'Get-ChildItem', 'Get-MdhDbSettings', 'md*') { { mdhelp $name } | Should Throw 'Get-Help' }
        { mdhelp -Examples } | Should Throw 'コマンド名'
        $bindingError = try { mdhelp mdsearch -Full -Examples; $null } catch { $_ }
        $bindingError.FullyQualifiedErrorId | Should Match 'AmbiguousParameterSet'
        ([Management.Automation.CommandCompletion]::CompleteInput('mdhelp mdse', 11, $null).CompletionMatches.CompletionText) | Should Be 'mdsearch'
        ([Management.Automation.CommandCompletion]::CompleteInput('mdlist con', 10, $null).CompletionMatches.CompletionText) -contains 'concept' | Should Be $true
    }
}
