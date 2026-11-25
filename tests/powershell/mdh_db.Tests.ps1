
. (Join-Path $PSScriptRoot '../../40_scripts/pwsh_scripts/mdh_common.ps1')
. (Join-Path $PSScriptRoot '../../40_scripts/pwsh_scripts/mdh_db.ps1')

Describe 'MDH DB commands' {
    BeforeEach {
        $script:MDHRoot = Join-Path $TestDrive 'MDH root 日本'
        $script:MDH_CONFIG = [pscustomobject]@{
            paths = [pscustomobject]@{ daily = '人工 日報' }
            db = [pscustomobject]@{ store_dir = '派生 DB'; python = $env:MDH_TEST_PYTHON_EXECUTABLE }
        }
    }

    It 'derives a stable Windows root identifier and separates moved roots' {
        $previous = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $TestDrive
            $root = $script:MDHRoot
            $script:MDH_CONFIG.PSObject.Properties.Remove('db')
            $first = (Get-MdhDbSettings).Store
            $script:MDHRoot = $root.ToUpperInvariant().Replace('\', '/') + '/'
            (Get-MdhDbSettings).Store | Should Be $first
            $script:MDHRoot = $root + ' moved'
            ((Get-MdhDbSettings).Store -ne $first) | Should Be $true
            (Split-Path -Leaf $first) | Should Match '^[0-9a-f]{64}$'
            (Test-Path -LiteralPath $first) | Should Be $false
        }
        finally { $env:LOCALAPPDATA = $previous }
    }

    It 'resolves an explicit relative store against the MDH root' {
        (Get-MdhDbSettings).Store | Should Be (Join-Path $script:MDHRoot '派生 DB')
    }

    It 'loads existing commands with a legacy config that has no DB section' {
        $loader = Join-Path $script:MDHRoot '40_scripts/pwsh_scripts'
        $settingsDir = Join-Path $script:MDHRoot '50_settings'
        New-Item -ItemType Directory -Path $loader, $settingsDir -Force | Out-Null
        Copy-Item (Join-Path $PSScriptRoot '../../40_scripts/pwsh_scripts/mdh*.ps1') -Destination $loader
        $legacy = '{"paths":{"MDH_root":""}}'
        $config = Join-Path $settingsDir 'config.json'
        [IO.File]::WriteAllText($config, $legacy)
        . (Join-Path $loader 'mdh.ps1')
        foreach ($name in 'daily', 'todo', 'quicklinks', 'md-db', 'mdsearch') {
            (Get-Command $name -ErrorAction Stop).CommandType.ToString() | Should Be 'Function'
        }
        [IO.File]::ReadAllText($config) | Should Be $legacy
    }

    It 'removes a partial temporary configuration after a template copy failure' {
        $isolatedRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $loader = Join-Path $isolatedRoot '40_scripts/pwsh_scripts'
        $settingsDir = Join-Path $isolatedRoot '50_settings'
        New-Item -ItemType Directory -Path $loader, $settingsDir -Force | Out-Null
        $source = Join-Path $PSScriptRoot '../../40_scripts/pwsh_scripts/mdh.ps1'
        $entry = Join-Path $loader 'mdh.ps1'
        $template = Join-Path $settingsDir 'config.template.json'
        $templateText = '{"paths":{"MDH_root":""}}'
        [IO.File]::WriteAllText($template, $templateText)
        $code = [IO.File]::ReadAllText($source)
        $point = '[IO.File]::Copy($MDHConfigTemplate, $temporary, $false)'
        $code.Contains($point) | Should Be $true
        $fault = '[IO.File]::WriteAllText($temporary, "partial"); throw [IO.IOException]::new("injected template copy failure")'
        [IO.File]::WriteAllText($entry, $code.Replace($point, $fault))

        $failure = try { . $entry; '' } catch { $_.Exception.Message }

        $failure | Should Match 'injected template copy failure'
        (Test-Path -LiteralPath (Join-Path $settingsDir 'config.json')) | Should Be $false
        @(Get-ChildItem -LiteralPath $settingsDir -Filter '*.tmp').Count | Should Be 0
        [IO.File]::ReadAllText($template) | Should Be $templateText
    }

    It 'does not invoke Python or create a store for Rebuild WhatIf' {
        $script:MDH_CONFIG.db.python = 'does not exist.exe'
        $response = md-db -Rebuild -WhatIf
        ($null -eq $response) | Should Be $true
        (Test-Path -LiteralPath (Get-MdhDbSettings).Store) | Should Be $false
    }

    It 'returns code 3 for an invalid explicit Python without falling back' {
        $script:MDH_CONFIG.db.python = 'does not exist.exe'
        $response = md-db -ErrorAction SilentlyContinue
        $response.exit_code | Should Be 3
        $LASTEXITCODE | Should Be 3
    }

    It 'returns code 3 when no Python is available' {
        $previous = $env:Path
        try {
            $env:Path = ''
            $script:MDH_CONFIG.db.python = ''
            (md-db -ErrorAction SilentlyContinue).exit_code | Should Be 3
        }
        finally { $env:Path = $previous }
    }

    It 'lists every match and keeps the response on the success stream' {
        Mock Invoke-MdhDbCommand {
            [pscustomobject]@{
                contract_version = 1; operation = 'search'; exit_code = 0; diagnostics = @()
                result = [pscustomobject]@{
                    incomplete = $false; stale_in_scope = 0; undated_invalid = 0
                    excluded = [pscustomobject]@{ STALE = 0 }; last_full_success = '2026-11-23T00:00:00Z'
                    hits = @([pscustomobject]@{
                        day = '2026-11-19'; title = '図書A'; path = '2026/2026-11/2026-11-19.md'; kind = 'topic'
                        status = 'CURRENT'; from_last_good_snapshot = $false; snapshot_hash = 'indexed'
                        matches = @(
                            [pscustomobject]@{ line = 10; excerpt = '図書' }
                            [pscustomobject]@{ line = 10; excerpt = '評価' }
                            [pscustomobject]@{ line = 14; excerpt = '整理' }
                        )
                    })
                }
            }
        } -ParameterFilter { $Operation -eq 'search' -and $Arguments -contains '--query=図書 整理' }
        Mock Read-MdhTextFile {
            [pscustomobject]@{ Hash = 'changed'; Content = '最新の原文' }
        } -ParameterFilter { [IO.Path]::GetFileName($Path) -eq '2026-11-19.md' }

        $plain = @(mdsearch '図書 整理' -Raw 6>&1)
        $plain.Count | Should Be 1
        $plain[0].contract_version | Should Be 1
        $listed = @(mdsearch '図書 整理' 6>&1)
        $messages = ($listed | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) -join "`n"
        $relative = '人工 日報\2026\2026-11\2026-11-19.md'
        ([regex]::Matches($messages, '2026-11-19 \| 図書A')).Count | Should Be 1
        $messages | Should Match '索引 L10 \| 図書 / 評価'
        $messages | Should Match '索引 L14 \| 整理'
        $messages | Should Match '行番号は索引作成時の位置'
        $messages | Should Match ([regex]::Escape($relative))
        $messages | Should Match '図書'
        $messages | Should Match '整理'
        $messages | Should Match '1 Topics / 2 matching lines'
        $messages.Contains('最新の原文') | Should Be $false
        $messages.Contains('contract_version') | Should Be $false
        @($listed | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }).Count | Should Be 0
        ((mdsearch '図書 整理' -DebugInfo 6>&1) -join "`n") | Should Match 'contract_version'
        $LASTEXITCODE | Should Be 0

        $absolute = Join-Path $script:MDHRoot $relative
        $full = @(mdsearch '図書 整理' -List -FullPath 6>&1)
        (($full | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) -join "`n") |
            Should Match ([regex]::Escape($absolute))
    }

    It 'highlights code point columns without corrupting Unicode or plain output' {
        $line = "📚 e$([char]0x0301) 👩‍🏫 図書と整理"
        $matches = @(
            [pscustomobject]@{ column = 3; excerpt = "e$([char]0x0301)" }
            [pscustomobject]@{ column = 6; excerpt = '👩‍🏫' }
            [pscustomobject]@{ column = 10; excerpt = '図書' }
            [pscustomobject]@{ column = 13; excerpt = '整理' }
        )
        (Format-MdhSearchLine -Line $line -Matches $matches) | Should Be $line
        $highlighted = Format-MdhSearchLine -Line $line -Matches $matches -Highlight
        foreach ($match in $matches) {
            $highlighted.Contains("$([char]27)[33m$($match.excerpt)$([char]27)[0m") | Should Be $true
        }
        ($highlighted -replace '\x1b\[[0-9;]*m', '') | Should Be $line
    }

    It 'reports a child process failure without displaying a successful search' {
        $script:MDH_CONFIG.db.python = 'test-child-failure.exe'
        Mock Resolve-MdhDbPython { $Settings.Python } -ParameterFilter {
            $Settings.Python -like '*test-child-failure.exe'
        }
        Mock Invoke-MdhDbProcess { throw 'injected child process failure' } -ParameterFilter {
            $Python -like '*test-child-failure.exe' -and $Operation -eq 'search'
        }
        $failure = mdsearch 'test-child' -Raw -ErrorAction SilentlyContinue
        $failure.exit_code | Should Be 4
        $failure.diagnostics[0].code | Should Be 'PYTHON_PROCESS_FAILED'
        $LASTEXITCODE | Should Be 4
        $display = @(mdsearch 'test-child' -ErrorAction SilentlyContinue 6>&1)
        @($display | Where-Object { $_ -isnot [Management.Automation.InformationRecord] }).Count | Should Be 0
        ($display -join ' ') | Should Match '検索に失敗.*md-db -Status'
        $LASTEXITCODE | Should Be 4
    }

    It 'merges overlap, highlights repeated ASCII matches, and renders source controls visibly' {
        $line = "📚 SQLite SQL $([char]27)[2J Ä ä"
        $matches = @(
            [pscustomobject]@{ column = 3; excerpt = 'SQLite'; term = 'SQLite' }
            [pscustomobject]@{ column = 3; excerpt = 'SQL'; term = 'sql' }
            [pscustomobject]@{ column = 20; excerpt = 'Ä'; term = 'Ä' }
        )
        (Format-MdhSearchLine -Line $line -Matches $matches) | Should Be '📚 SQLite SQL \u001B[2J Ä ä'
        $colored = Format-MdhSearchLine -Line $line -Matches $matches -Highlight
        $colored | Should Match ([regex]::Escape("$([char]27)[33mSQLite$([char]27)[0m $([char]27)[33mSQL$([char]27)[0m"))
        $colored | Should Not Match ([regex]::Escape("$([char]27)[2J"))
        $colored | Should Not Match ([regex]::Escape("$([char]27)[33mä"))
    }

    It 'validates extended requests before either source and emits Raw before a terminating error' {
        Mock Invoke-MdhDbCommand { throw 'Daily should not run' } -ParameterFilter {
            $Operation -eq 'search' -and ($Arguments -contains '--query=term' -or
                $Arguments -contains "--query=bad$([char]0)query")
        }
        Mock Invoke-MdhQuickNotesSearch { throw 'QuickNotes should not run' } -ParameterFilter {
            $Query -eq 'term' -or $Query -eq "bad$([char]0)query"
        }
        foreach ($options in @(
            @{ Scope = 'All'; From = '2026-02-30' },
            @{ Scope = 'All'; From = '2026-11-24'; To = '2026-11-23' },
            @{ Scope = 'QuickNotes'; IncludeStale = $true }
        )) {
            $r = mdsearch 'term' @options -Raw -ErrorAction SilentlyContinue
            $r.exit_code | Should Be 2
            $r.sources.PSObject.Properties.Name | Should BeNullOrEmpty
            $LASTEXITCODE | Should Be 2
        }
        $seen = [Collections.Generic.List[object]]::new()
        try {
            mdsearch "bad$([char]0)query" -Scope All -Raw -ErrorAction Stop | ForEach-Object { $seen.Add($_) }
            throw 'Expected a terminating error'
        }
        catch { $_.FullyQualifiedErrorId | Should Match 'MDH_SEARCH_2' }
        $seen.Count | Should Be 1
        $seen[0].status | Should Be 'error'
        Assert-MockCalled Invoke-MdhDbCommand -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-MdhQuickNotesSearch -Times 0 -Exactly -Scope It
    }

    It 'searches notes without a DB and isolates success, partial failure and total failure' -Skip:(-not $env:MDH_TEST_PYTHON_EXECUTABLE) {
        $script:MDHRoot = Join-Path $TestDrive 'isolated cross-source search'
        $notes = Join-Path $TestDrive "外部 Notes O'Brien"
        $null = New-Item -ItemType Directory -Force -Path $notes
        $script:MDH_CONFIG.paths | Add-Member -NotePropertyName quicknotes -NotePropertyValue $notes
        $note = Join-Path $notes 'Ideas.md'
        [IO.File]::WriteAllLines($note, @('# Ideas', 'SQL', 'index'))
        $before = (Get-FileHash -LiteralPath $note).Hash
        $store = (Get-MdhDbSettings).Store
        $script:MDH_CONFIG.db.store_dir = '\\invalid\store'
        $quick = @(mdsearch 'SQL index' -Scope QuickNotes -Raw -DebugInfo 6>$null)
        $quick.Count | Should Be 1
        $quick[0].status | Should Be 'success'
        $quick[0].sources.PSObject.Properties.Name | Should Be 'quicknotes'
        $quick[0].sources.quicknotes.result.matching_lines | Should Be 2
        (Get-FileHash -LiteralPath $note).Hash | Should Be $before
        $script:MDH_CONFIG.db.store_dir = $store
        (Test-Path -LiteralPath $store) | Should Be $false
        $partial = mdsearch 'SQL index' -Scope All -Raw -ErrorAction SilentlyContinue
        $partial.status | Should Be 'partial'
        $partial.sources.daily.response.diagnostics[0].code | Should Be 'ACTIVE_DATABASE_ERROR'
        $partial.sources.quicknotes.result.files_matched | Should Be 1
        $LASTEXITCODE | Should Be 1
        $display = (mdsearch 'SQL index' -Scope All -ErrorAction SilentlyContinue 6>&1) -join [Environment]::NewLine
        $display | Should Match '===== DAILY =====[\s\S]*検索失敗[\s\S]*===== QUICKNOTES ====='
        $display | Should Match ([regex]::Escape($note))
        $display | Should Match '部分失敗'
        $display | Should Not Match ([string][char]27)

        $daily = Join-Path (Get-MdhDbSettings).Daily '2026/2026-11/2026-11-22.md'
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $daily)
        [IO.File]::WriteAllLines($daily, @('# ✅ やったこと', '', '## SQL', 'index'))
        (md-db -Rebuild -Confirm:$false).exit_code | Should Be 0
        $db = Get-ChildItem -LiteralPath $store -Filter '*.sqlite' | Select-Object -First 1
        $dbHash = (Get-FileHash -LiteralPath $db.FullName).Hash
        $rawDaily = mdsearch 'SQL index' -Raw
        $explicit = mdsearch 'SQL index' -Scope Daily -Raw
        ($rawDaily | ConvertTo-Json -Depth 15) | Should Be ($explicit | ConvertTo-Json -Depth 15)
        $all = mdsearch 'SQL index' -Scope All -From '2026-11-22' -To '2026-11-22' -Raw
        $all.status | Should Be 'success'
        $all.sources.daily.filters.from | Should Be '2026-11-22'
        $all.sources.daily.response.result.hits.Count | Should Be 1
        $all.sources.quicknotes.result.files_matched | Should Be 1
        $both = (mdsearch 'SQL index' -Scope All -From '2026-11-22' -FullPath -List 6>&1) -join [Environment]::NewLine
        $both | Should Match '2 Groups / 4 matching lines'
        $both | Should Match 'QuickNotesには日付制限を適用しません'
        [IO.File]::WriteAllText($note, 'note-only')
        $noCrossSource = mdsearch 'SQL note-only' -Scope All -Raw
        $noCrossSource.sources.daily.response.result.hits.Count | Should Be 0
        $noCrossSource.sources.quicknotes.result.files_matched | Should Be 0
        [IO.File]::WriteAllBytes((Join-Path $notes 'invalid.md'), [byte[]]@(255))
        $incomplete = mdsearch 'note-only' -Scope QuickNotes -Raw -WarningAction SilentlyContinue
        $incomplete.status | Should Be 'success'
        $incomplete.sources.quicknotes.result.incomplete | Should Be $true
        $incomplete.sources.quicknotes.result.files_matched | Should Be 1
        $script:MDH_CONFIG.paths.quicknotes = Join-Path $notes 'missing'
        $partial = mdsearch SQL -Scope All -Raw -ErrorAction SilentlyContinue
        $partial.status | Should Be 'partial'
        $partial.sources.daily.response.result.hits.Count | Should Be 1
        $partial.sources.quicknotes.diagnostics[0].code | Should Be 'QUICKNOTES_ROOT'
        (Get-FileHash -LiteralPath $db.FullName).Hash | Should Be $dbHash
        $script:MDH_CONFIG.db.store_dir = Join-Path $TestDrive 'absent database'
        $bothFailed = mdsearch SQL -Scope All -Raw -ErrorAction SilentlyContinue
        $bothFailed.status | Should Be 'error'
        $bothFailed.exit_code | Should Be 4
        $bothFailed.sources.daily.status | Should Be 'error'
        $bothFailed.sources.quicknotes.status | Should Be 'error'
    }

    It 'keeps same-title groups separate and counts only the distinct matching rows in each group' {
        $relative = '2026/2026-11/2026-11-18.md'
        Mock Read-MdhTextFile { throw 'injected missing source' } -ParameterFilter { $Path -like '*2026-11-18.md' }
        $first = [pscustomobject]@{ line = 12; excerpt = ('long-' + ('x' * 400)) }
        $second = [pscustomobject]@{ line = 2; excerpt = 'heading hit' }
        $control = [pscustomobject]@{ line = 3; excerpt = "safe$([char]27)[2J" }
        $result = [pscustomobject]@{ incomplete = $false; hits = @(
            [pscustomobject]@{ kind='topic'; group_start=20; day='2026-11-18'; title='Same'; path=$relative;
                status='CURRENT'; snapshot_hash='indexed'; matches=@($first,$second,$second) },
            [pscustomobject]@{ kind='topic'; group_start=120; day='2026-11-18'; title='Same'; path=$relative;
                status='CURRENT'; snapshot_hash='indexed'; matches=@($control) },
            [pscustomobject]@{ kind='preamble'; group_start=0; day='2026-11-18'; title=''; path=$relative;
                status='CURRENT'; snapshot_hash='indexed'; matches=@($second) }
        ) }
        $display = (Write-MdhSearchList -Query search -Result $result 6>&1) -join [Environment]::NewLine
        ([regex]::Matches($display, '2026-11-18 \| Same')).Count | Should Be 2
        $display | Should Match '3 Groups \(2 Topics\) / 4 matching lines'
        $display | Should Match '索引 L2[\s\S]+索引 L12'
        $display | Should Match ([regex]::Escape($first.excerpt))
        $display | Should Match '前文'
        $display | Should Not Match ([string][char]27)
    }

    It 'runs all commands through Python and preserves a partial sync result' -Skip:(-not $env:MDH_TEST_PYTHON_EXECUTABLE) {
        $settings = Get-MdhDbSettings
        $path = Join-Path $settings.Daily '2026/2026-11/2026-11-22.md'
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        $fixture = Join-Path $PSScriptRoot '../python/mdh_db/fixtures/new_daily_crlf.md'
        [IO.File]::WriteAllBytes($path, [IO.File]::ReadAllBytes($fixture))
        $hash = (Get-FileHash -LiteralPath $path).Hash

        $status = md-db -WarningAction SilentlyContinue
        $status.operation | Should Be 'status'
        $status.result.initialized | Should Be $false
        (mdsearch '貸出集計' -Raw -ErrorAction SilentlyContinue).exit_code | Should Be 4
        (Test-Path -LiteralPath $settings.Store) | Should Be $false
        (md-db -Rebuild -Confirm:$false).exit_code | Should Be 0
        (Get-FileHash -LiteralPath $path).Hash | Should Be $hash
        (md-db -Status).result.counts.CURRENT | Should Be 1
        $otherDaily = Join-Path $TestDrive 'another Daily root'
        $null = New-Item -ItemType Directory -Path $otherDaily
        $script:MDH_CONFIG.paths.daily = $otherDaily
        try {
            $mismatch = @(md-db -Status 3>&1)
            $mismatch[0].result.daily_root_matches | Should Be $false
            $mismatch[0].diagnostics[0].code | Should Be 'DAILY_ROOT_MISMATCH'
            ($mismatch[1] -is [Management.Automation.WarningRecord]) | Should Be $true
            $search = @(mdsearch '貸出集計' -Raw 3>&1)
            $search[0].exit_code | Should Be 4
            $search[0].result | Should Be $null
            ($search[1] -is [Management.Automation.WarningRecord]) | Should Be $true
        }
        finally {
            $script:MDH_CONFIG.paths.daily = $settings.Daily
        }

        $listing = @(mdsearch '図書A　貸出集計' -From '2026-11-22' -To '2026-11-22' -List 6>&1)
        ($listing -join "`n") | Should Match '貸出集計📚'
        ($listing -join "`n") | Should Match 'L8 \|'
        ($listing -join "`n") | Should Not Match '索引 L8'
        $response = mdsearch '図書A　貸出集計' -Raw -From '2026-11-22' -To '2026-11-22'
        $response.result.hits[0].title | Should Be '図書A'
        $response.result.hits[0].path | Should Be '2026/2026-11/2026-11-22.md'
        (md-db -Sync -ConfirmDeletions @('..\outside.md', '2026/2026-11/2026-11-22.md') -ErrorAction SilentlyContinue).exit_code | Should Be 2

        $bad = Join-Path $PSScriptRoot '../python/mdh_db/fixtures/sync_invalid.md'
        [IO.File]::WriteAllBytes($path, [IO.File]::ReadAllBytes($bad))
        $partial = md-db -Sync -WarningAction SilentlyContinue
        $LASTEXITCODE | Should Be 1
        $partial.exit_code | Should Be 1
        $partial.result.failed | Should Be 1
        $partial.diagnostics.Count | Should Be 1

        $listing = @(mdsearch '貸出集計' -List -WarningAction SilentlyContinue 6>&1)
        ($listing -join "`n") | Should Match '一致する日報はありませんでした'
        ($listing -join "`n") | Should Match '不完全.*STALE=1'
        $zero = mdsearch '貸出集計' -Raw -WarningAction SilentlyContinue
        $zero.exit_code | Should Be 0
        $zero.result.hits.Count | Should Be 0
        $zero.result.incomplete | Should Be $true
        $zero.result.excluded.STALE | Should Be 1
        $listing = @(mdsearch '貸出集計' -List -IncludeStale -WarningAction SilentlyContinue 6>&1)
        ($listing -join "`n") | Should Match 'STALE・最後の正常スナップショット上の位置'
        ($listing -join "`n") | Should Match '現在のファイル位置と一致する保証はありません'
        ($listing -join "`n") | Should Match '索引 L8'
    }
}

Describe 'MDH DB end-to-end from the production loader' {
    It 'protects sources, holds deletions, switches readers and recovers through a separate store' -Skip:(-not $env:MDH_TEST_PYTHON_EXECUTABLE) {
        $root = Join-Path $TestDrive '統合 リポジトリ'
        $scripts = Join-Path $root '40_scripts'
        $settings = Join-Path $root '50_settings'
        New-Item -ItemType Directory -Path $scripts, $settings -Force | Out-Null
        Copy-Item (Join-Path $PSScriptRoot '../../40_scripts/pwsh_scripts') -Destination $scripts -Recurse
        $package = Join-Path $scripts 'py_scripts/mdh_db'
        New-Item -ItemType Directory -Path $package -Force | Out-Null
        Copy-Item (Join-Path $PSScriptRoot '../../40_scripts/py_scripts/mdh_db/*.*') -Destination $package
        $config = @{
            paths = @{ MDH_root = ''; daily = '人工 日報' }
            db = @{ python = $env:MDH_TEST_PYTHON_EXECUTABLE; store_dir = '隔離 ストア' }
        }
        $configPath = Join-Path $settings 'config.json'
        $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding utf8
        $loader = Join-Path $scripts 'pwsh_scripts/mdh.ps1'
        . $loader

        $month = Join-Path $root '人工 日報/2026/2026-11'
        New-Item -ItemType Directory -Path $month -Force | Out-Null
        $fixture = Join-Path $PSScriptRoot '../python/mdh_db/fixtures/new_daily_crlf.md'
        $bad = Join-Path $PSScriptRoot '../python/mdh_db/fixtures/sync_invalid.md'
        $days = @(20..23 | ForEach-Object { Join-Path $month "2026-11-$_.md" })
        $first = $days[0]
        foreach ($day in $days[0..2]) {
            [IO.File]::WriteAllBytes($day, [IO.File]::ReadAllBytes($fixture))
        }
        $untouched = (Get-FileHash -LiteralPath $days[1]).Hash
        $store = Join-Path $root '隔離 ストア'
        $pointer = Join-Path $store 'active'

        (md-db -WarningAction SilentlyContinue).result.initialized | Should Be $false
        md-db -Rebuild -WhatIf
        (Test-Path -LiteralPath $store) | Should Be $false
        (md-db -Rebuild -Confirm:$false).result.indexed | Should Be 3
        (mdsearch '図書A　貸出集計' -Raw).result.hits.Count | Should Be 3
        (mdsearch '該当しない言葉' -Raw).result.incomplete | Should Be $false
        (mdsearch '該当しない言葉' -Raw).result.hits.Count | Should Be 0

        $edited = [IO.File]::ReadAllText($fixture).Replace('貸出集計', '追記した日本語')
        [IO.File]::WriteAllText($first, $edited)
        $editedHash = (Get-FileHash -LiteralPath $first).Hash
        (md-db -Sync).result.indexed | Should Be 1
        (md-db -Sync).result.unchanged | Should Be 3
        (mdsearch '追記した日本語' -Raw).result.hits.Count | Should Be 1
        (Get-FileHash -LiteralPath $first).Hash | Should Be $editedHash

        [IO.File]::WriteAllBytes($first, [IO.File]::ReadAllBytes($bad))
        [IO.File]::WriteAllBytes($days[3], [IO.File]::ReadAllBytes($bad))
        $partial = md-db -Sync -WarningAction SilentlyContinue
        $partial.exit_code | Should Be 1
        $partial.result.failed | Should Be 2
        $coverage = (mdsearch '追記した日本語' -Raw -WarningAction SilentlyContinue).result
        $coverage.hits.Count | Should Be 0
        $coverage.incomplete | Should Be $true
        $coverage.excluded.STALE | Should Be 1
        $coverage.excluded.INVALID | Should Be 1
        (mdsearch '追記した日本語' -Raw -IncludeStale -WarningAction SilentlyContinue).result.hits[0].from_last_good_snapshot | Should Be $true
        [IO.File]::WriteAllText($first, $edited)
        [IO.File]::WriteAllBytes($days[3], [IO.File]::ReadAllBytes($fixture))
        (md-db -Sync).result.indexed | Should Be 2

        [IO.File]::Delete($days[2])
        $deletion = @('2026/2026-11/2026-11-22.md')
        (md-db -Sync -ConfirmDeletions $deletion -WarningAction SilentlyContinue).result.deleted | Should Be 0
        (md-db -Status -WarningAction SilentlyContinue).result.counts.MISSING | Should Be 1
        $previous = [IO.File]::ReadAllText($pointer)
        (md-db -Rebuild -Confirm:$false -ErrorAction SilentlyContinue).exit_code | Should Be 6
        [IO.File]::ReadAllText($pointer) | Should Be $previous
        (mdsearch '追記した日本語' -Raw -WarningAction SilentlyContinue).result.hits.Count | Should Be 1
        (md-db -Sync -ConfirmDeletions $deletion).result.deleted | Should Be 1

        # A separate process holds a real SQLite read transaction on the old generation.
        $reader = [Diagnostics.ProcessStartInfo]::new($env:MDH_TEST_PYTHON_EXECUTABLE)
        $reader.UseShellExecute = $false
        $reader.RedirectStandardInput = $true
        $reader.RedirectStandardOutput = $true
        $readerCode = 'import pathlib, sqlite3, sys; db=sqlite3.connect(pathlib.Path(sys.argv[1]).as_uri()+"?mode=ro", uri=True); db.execute("BEGIN"); print(db.execute("SELECT COUNT(*) FROM daily").fetchone()[0], flush=True); input(); print(db.execute("SELECT COUNT(*) FROM daily").fetchone()[0], flush=True)'
        foreach ($arg in @('-B', '-c', $readerCode, (Join-Path $store $previous.Trim()))) {
            $reader.ArgumentList.Add($arg)
        }
        $process = [Diagnostics.Process]::Start($reader)
        try {
            $ready = $process.StandardOutput.ReadLineAsync()
            $ready.Wait(15000) | Should Be $true
            $ready.Result | Should Be '3'
            $added = Join-Path $month '2026-11-24.md'
            [IO.File]::WriteAllBytes($added, [IO.File]::ReadAllBytes($fixture))
            (md-db -Rebuild -Confirm:$false).result.indexed | Should Be 4
            ([IO.File]::ReadAllText($pointer) -ne $previous) | Should Be $true
            (mdsearch '図書A' -Raw).result.hits.Count | Should Be 8
            $process.StandardInput.WriteLine('')
            $stillReading = $process.StandardOutput.ReadLineAsync()
            $stillReading.Wait(15000) | Should Be $true
            $stillReading.Result | Should Be '3'
            $process.WaitForExit(15000) | Should Be $true
            $process.ExitCode | Should Be 0
        }
        finally {
            if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            $process.Dispose()
        }

        $published = [IO.File]::ReadAllText($pointer)
        # Windows denies pointer replacement while this handle omits FileShare.Delete.
        $heldPointer = [IO.File]::Open($pointer, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            (md-db -Rebuild -Confirm:$false -ErrorAction SilentlyContinue).exit_code | Should Be 6
            [IO.File]::ReadAllText($pointer) | Should Be $published
            (mdsearch '追記した日本語' -Raw).result.hits.Count | Should Be 1
        }
        finally { $heldPointer.Dispose() }

        [IO.File]::WriteAllText($pointer, "db-00000000000000000000000000000000.sqlite`n")
        (md-db -Status -ErrorAction SilentlyContinue).exit_code | Should Be 4
        [IO.File]::WriteAllText($pointer, 'broken')
        (md-db -Status -ErrorAction SilentlyContinue).exit_code | Should Be 4
        (mdsearch '図書A' -Raw -ErrorAction SilentlyContinue).exit_code | Should Be 4
        (md-db -Rebuild -Confirm:$false -ErrorAction SilentlyContinue).exit_code | Should Be 4

        # Restore only a known published generation for inspection in a separate store.
        $archive = Join-Path $root '旧世代 検証'
        New-Item -ItemType Directory -Path $archive | Out-Null
        Copy-Item -LiteralPath (Join-Path $store $previous.Trim()) -Destination $archive
        [IO.File]::WriteAllText((Join-Path $archive 'active'), $previous, [Text.Encoding]::ASCII)
        $config.db.store_dir = '旧世代 検証'
        $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding utf8
        . $loader
        (md-db -Status).result.generation | Should Be $previous.Trim()
        (mdsearch '図書A' -Raw).result.hits.Count | Should Be 6

        $config.db.store_dir = '復旧 ストア'
        $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding utf8
        . $loader
        (md-db -Rebuild -Confirm:$false).result.indexed | Should Be 4
        (md-db -Status).result.counts.CURRENT | Should Be 4
        [IO.File]::ReadAllText($pointer) | Should Be 'broken'
        (Test-Path -LiteralPath (Join-Path $store $previous.Trim())) | Should Be $true
        (Get-FileHash -LiteralPath $first).Hash | Should Be $editedHash
        (Get-FileHash -LiteralPath $days[1]).Hash | Should Be $untouched

        $script:MDH_CONFIG.db.store_dir = 42
        (md-db -Status -ErrorAction SilentlyContinue).exit_code | Should Be 2
        $script:MDH_CONFIG.db.store_dir = '復旧 ストア'
        $script:MDH_CONFIG.db.python = '存在しない python.exe'
        (md-db -Status -ErrorAction SilentlyContinue).exit_code | Should Be 3
    }
}
