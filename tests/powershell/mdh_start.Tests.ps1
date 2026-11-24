$startupScripts = Join-Path $PSScriptRoot '../../40_scripts/pwsh_scripts'
$startupTemplate = Join-Path $PSScriptRoot '../../50_settings/templates/DailyTemplate.md'
foreach ($scriptName in 'common', 'init', 'daily', 'todo', 'quicklinks', 'db', 'start') {
    . (Join-Path $startupScripts "mdh_$scriptName.ps1")
}

function Set-TestStartupDaily {
    param([string]$DateText, [string]$Content)
    $path = Get-MdhDailyPath -DateText $DateText
    Ensure-Directory -Path (Split-Path -Parent $path)
    [IO.File]::WriteAllText($path, $Content)
    return $path
}

Describe 'mdstart' {
    BeforeEach {
        $script:MDHRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $quicknotes = Join-Path $script:MDHRoot 'Quick Notes'
        $dailyRoot = Join-Path $script:MDHRoot 'Daily'
        Ensure-Directory -Path $quicknotes
        Ensure-Directory -Path $dailyRoot
        $routine = Join-Path $script:MDHRoot 'routine.md'
        [IO.File]::WriteAllText($routine, '- [ ] routine item')
        $script:MDH_CONFIG = [pscustomobject]@{
            paths = [pscustomobject]@{ quicknotes = $quicknotes; daily = $dailyRoot }
            daily = [pscustomobject]@{ template = $startupTemplate; update_schedule = $false }
            todo = [pscustomobject]@{ file = '{quicknotes}\todo.md'; routine_file = $routine }
            startup = [pscustomobject]@{ open_files = @('{todo}', '{previous_daily}', '{today_daily}') }
        }
        $script:startupCalls = [Collections.Generic.List[string]]::new()
        $script:startupOpened = [Collections.Generic.List[string]]::new()
        $script:startupOpenFailure = $null
        $script:startupClockReads = 0
        $script:startupDate = '2026-11-23'
        $script:startupStatus = [pscustomobject]@{
            initialized = $false; generation = $null; incomplete = $true
            counts = [pscustomobject]@{ CURRENT = 0; STALE = 0; INVALID = 0; MISSING = 0; DELETED = 0 }
            last_attempt = $null; last_full_success = $null
        }
        $script:startupDbResponses = @{
            status = [pscustomobject]@{ contract_version = 1; operation = 'status'; exit_code = 0; diagnostics = @(); result = $script:startupStatus }
            rebuild = [pscustomobject]@{
                contract_version = 1; operation = 'rebuild'; exit_code = 0; diagnostics = @()
                result = [pscustomobject]@{ path = 'test.sqlite'; indexed = 1 }
            }
            sync = [pscustomobject]@{
                contract_version = 1; operation = 'sync'; exit_code = 0; diagnostics = @()
                result = [pscustomobject]@{ completed = $true; failed = 0; missing = 0; scan_error = $null }
            }
        }
        Mock Get-Date {
            $script:startupClockReads++
            if ($script:startupClockReads -eq 1) { [datetime]'2026-11-23T23:59:59' }
            else { [datetime]'2026-11-24T00:00:01' }
        }
        Mock Get-MdhDailyAppointments { [pscustomobject]@{ Status = 'Available'; Appointments = @() } }
        Mock Invoke-MdhDbCommand {
            $script:startupCalls.Add($Operation)
            if ($Operation -eq 'status') {
                # Both Markdown stages must have completed before Status.
                if (-not (Test-Path -LiteralPath (Get-MdhDailyPath -DateText $script:startupDate) -PathType Leaf) -or
                    -not (Test-Path -LiteralPath (Get-MdhTodoPath) -PathType Leaf)) {
                    throw 'Markdown stages did not finish before Status'
                }
            }
            if ($Operation -eq 'rebuild' -and '--only-if-uninitialized' -notin $Arguments) {
                throw 'Missing first-rebuild guard'
            }
            $script:startupDbResponses[$Operation]
        }
        Mock Open-IfExist {
            if ($Path -eq $script:startupOpenFailure) { throw 'VS Code launch failed' }
            $script:startupOpened.Add($Path)
        }
    }

    It 'creates Daily before TODO, then checks Status and rebuilds once without Sync' {
        [IO.File]::WriteAllText((Get-MdhTodoPath), "# TODO`n`n## Tasks`n- [x] before startup")
        $output = (mdstart -NoOpen 6>&1) -join "`n"
        ($script:startupCalls -join ',') | Should Be 'status,rebuild'
        [IO.File]::ReadAllText((Get-MdhDailyPath -DateText $script:startupDate)) | Should Match 'before startup'
        [IO.File]::ReadAllText((Get-MdhTodoPath)) | Should Not Match 'before startup'
        $output | Should Match 'rebuild 完了'
        $script:startupOpened.Count | Should Be 0
    }

    It 'syncs an initialized DB without rebuilding' {
        $script:startupStatus.initialized = $true
        $script:startupStatus.generation = 'db-0123456789abcdef0123456789abcdef.sqlite'
        $output = (mdstart -NoOpen 6>&1) -join "`n"
        ($script:startupCalls -join ',') | Should Be 'status,sync'
        $output | Should Match 'sync 完了'
    }

    It 'repeats the same date without duplicating Daily, TODO history or routines' {
        [IO.File]::WriteAllText((Get-MdhTodoPath), "# TODO`n`n## Tasks`n- [x] completion`n- [ ] manual task")
        mdstart -NoOpen -SkipDb
        $path = Get-MdhDailyPath -DateText $script:startupDate
        [IO.File]::AppendAllText($path, "`nmanual daily text`n")
        $script:startupClockReads = 0
        mdstart -NoOpen -SkipDb
        @(Get-MdhExistingDailyDates).Count | Should Be 1
        $dailyContent = [IO.File]::ReadAllText($path)
        ([regex]::Matches($dailyContent, 'completion')).Count | Should Be 1
        $dailyContent | Should Match 'manual daily text'
        $todoContent = [IO.File]::ReadAllText((Get-MdhTodoPath))
        ([regex]::Matches($todoContent, 'routine item')).Count | Should Be 1
        $todoContent | Should Match 'manual task'
        $todoContent | Should Match 'Quick Links'
        $script:startupCalls.Count | Should Be 0
        $script:startupOpened.Count | Should Be 0
    }

    It 'stops TODO and DB on a neighbor read failure and repairs the link on retry' {
        $old = "<!-- MDH:NAVIGATION:START -->`n<!-- MDH:NAVIGATION:END -->`n# Previous"
        $previous = Set-TestStartupDaily -DateText '2026-11-21' -Content $old
        $lock = [IO.File]::Open($previous, 'Open', 'ReadWrite', 'None')
        try {
            $output = (mdstart -NoOpen 3>&1 6>&1) -join "`n"
        }
        finally {
            $lock.Dispose()
        }
        $output | Should Match '隣接日報 2026-11-21'
        $output | Should Match 'Daily : 失敗'
        $script:startupCalls.Count | Should Be 0
        (Test-Path -LiteralPath (Get-MdhTodoPath)) | Should Be $false
        [IO.File]::ReadAllText($previous) | Should BeExactly $old
        (Test-Path -LiteralPath (Get-MdhDailyPath -DateText $script:startupDate)) | Should Be $true

        $script:startupClockReads = 0
        $output = (mdstart -NoOpen 3>&1 6>&1) -join "`n"
        $output | Should Match 'Daily : (完了|警告付き完了)'
        ($script:startupCalls -join ',') | Should Be 'status,rebuild'
        [IO.File]::ReadAllText($previous) | Should BeExactly "[→ 2026-11-23](2026-11-23.md)`n# Previous"
    }

    It 'keeps the updated previous Daily and skips TODO and DB if the next Daily fails' {
        $old = "<!-- MDH:NAVIGATION:START -->`n<!-- MDH:NAVIGATION:END -->`n# Daily"
        $previous = Set-TestStartupDaily -DateText '2026-11-21' -Content $old
        $next = Set-TestStartupDaily -DateText '2026-11-25' -Content $old
        $lock = [IO.File]::Open($next, 'Open', 'ReadWrite', 'None')
        try {
            $output = (mdstart -NoOpen 3>&1 6>&1) -join "`n"
        }
        finally {
            $lock.Dispose()
        }
        $output | Should Match '隣接日報 2026-11-25'
        $output | Should Match 'Daily : 失敗'
        [IO.File]::ReadAllText($previous) | Should BeExactly "[→ 2026-11-23](2026-11-23.md)`n# Daily"
        [IO.File]::ReadAllText($next) | Should BeExactly $old
        (Test-Path -LiteralPath (Get-MdhTodoPath)) | Should Be $false
        $script:startupCalls.Count | Should Be 0
    }

    It 'stops TODO and DB when the Daily template is missing and opens existing files' {
        $script:MDH_CONFIG.startup.open_files = @('{quicknotes}', '{today_daily}')
        $script:MDH_CONFIG.daily.template = Join-Path $script:MDHRoot 'missing-template.md'
        $output = (mdstart 3>&1 6>&1) -join "`n"
        $output | Should Match 'Daily : 失敗'
        $output | Should Match '省略（Daily 失敗）'
        (Test-Path -LiteralPath (Get-MdhTodoPath)) | Should Be $false
        $script:startupCalls.Count | Should Be 0
        $script:startupOpened.Count | Should Be 1
    }

    It 'stops DB and preserves checked TODO when Daily cannot accept archive entries' {
        $null = Set-TestStartupDaily -DateText $script:startupDate -Content "# Manual content`n"
        [IO.File]::WriteAllText((Get-MdhTodoPath), "# TODO`n`n## Tasks`n- [x] keep this")
        $output = (mdstart -NoOpen 3>&1 6>&1) -join "`n"
        $output | Should Match 'TODO  : 失敗'
        $output | Should Match '省略（TODO 失敗）'
        [IO.File]::ReadAllText((Get-MdhTodoPath)) | Should Match '\[x\] keep this'
        $script:startupCalls.Count | Should Be 0
    }

    It 'treats missing routine definitions as a TODO warning and still checks DB' {
        Remove-Item -LiteralPath $script:MDH_CONFIG.todo.routine_file
        $output = (mdstart -NoOpen 3>&1 6>&1) -join "`n"
        $output | Should Match 'TODO  : 警告付き完了'
        $output | Should Match '警告付き完了'
        ($script:startupCalls -join ',') | Should Be 'status,rebuild'
    }

    It 'stops on a Status process failure' {
        $script:startupDbResponses.status.exit_code = 3
        $output = (mdstart -NoOpen 3>&1 6>&1) -join "`n"
        $output | Should Match 'status 失敗'
        ($script:startupCalls -join ',') | Should Be 'status'
    }

    It 'rejects an invalid Status Boolean or exit-code type' {
        $script:startupStatus.initialized = 'false'
        $output = (mdstart -NoOpen 3>&1 6>&1) -join "`n"
        $output | Should Match 'status 失敗'
        $script:startupClockReads = 0
        $script:startupStatus.initialized = $false
        $script:startupDbResponses.status.exit_code = '0'
        $output = (mdstart -NoOpen 3>&1 6>&1) -join "`n"
        $output | Should Match 'status 失敗'
        ($script:startupCalls -join ',') | Should Be 'status,status'
    }

    It 'rejects corruption diagnostics and inconsistent pointer state even with exit code zero' {
        $script:startupDbResponses.status.diagnostics = @([pscustomobject]@{ code = 'ACTIVE_DATABASE_ERROR' })
        $output = (mdstart -NoOpen 3>&1 6>&1) -join "`n"
        $output | Should Match 'status 失敗'
        $script:startupClockReads = 0
        $script:startupDbResponses.status.diagnostics = @()
        $script:startupStatus.generation = 'db-0123456789abcdef0123456789abcdef.sqlite'
        $output = (mdstart -NoOpen 3>&1 6>&1) -join "`n"
        $output | Should Match 'status 失敗'
        ($script:startupCalls -join ',') | Should Be 'status,status'
    }

    It 'does not retry a failed Rebuild or call Sync, and continues opening files' {
        $script:startupDbResponses.rebuild.exit_code = 6
        $output = (mdstart 3>&1 6>&1) -join "`n"
        $output | Should Match 'rebuild 失敗'
        ($script:startupCalls -join ',') | Should Be 'status,rebuild'
        $script:startupOpened.Count | Should Be 2
    }

    It 'reports Sync failure and leaves the Daily available' {
        $script:startupStatus.initialized = $true
        $script:startupStatus.generation = 'db-0123456789abcdef0123456789abcdef.sqlite'
        $script:startupDbResponses.sync.exit_code = 4
        $output = (mdstart 3>&1 6>&1) -join "`n"
        $output | Should Match 'sync 失敗'
        ($script:startupCalls -join ',') | Should Be 'status,sync'
        $script:startupOpened.Contains((Get-MdhDailyPath -DateText $script:startupDate)) | Should Be $true
    }

    It 'reports a partial Sync as a warning and continues opening files' {
        $script:startupStatus.initialized = $true
        $script:startupStatus.generation = 'db-0123456789abcdef0123456789abcdef.sqlite'
        $script:startupDbResponses.sync.exit_code = 1
        $script:startupDbResponses.sync.result.completed = $false
        $script:startupDbResponses.sync.result.failed = 1
        $script:startupDbResponses.sync.diagnostics = @([pscustomobject]@{ code = 'INVALID_DAILY_DATE' })
        $output = (mdstart 3>&1 6>&1) -join "`n"
        $output | Should Match 'sync 警告付き完了'
        $output | Should Match 'INVALID_DAILY_DATE'
        $script:startupOpened.Count | Should Be 2
    }

    It 'uses the startup date across midnight, opens in order, and deduplicates normalized paths' {
        $null = Set-TestStartupDaily -DateText '2026-11-20' -Content '# older'
        $previous = Set-TestStartupDaily -DateText '2026-11-22' -Content '# previous'
        $null = Set-TestStartupDaily -DateText '2026-11-24' -Content '# tomorrow'
        $today = Get-MdhDailyPath -DateText $script:startupDate
        $script:MDH_CONFIG.startup.open_files = @('{today_daily}', 'Daily\2026\2026-11\..\2026-11\2026-11-23.md',
            'missing.md', '{previous_daily}', '{quicknotes}')
        [IO.File]::WriteAllText((Get-MdhTodoPath), "# TODO`n`n## Tasks`n- [x] midnight")
        $output = (mdstart -SkipDb -Verbose 3>&1 4>&1 6>&1) -join "`n"
        $output | Should Match 'VS Code : 表示要求 3 件、警告 1 件'
        $output | Should Match 'missing\.md'
        $output | Should Match '省略（-SkipDb）'
        ($script:startupOpened -join '|') | Should Be (@($today, $previous, $script:MDH_CONFIG.paths.quicknotes) -join '|')
        [IO.File]::ReadAllText($today) | Should Match '\[TODO 2026-11-23\].*midnight'
        $script:startupCalls.Count | Should Be 0
        $script:startupClockReads | Should Be 1
    }

    It 'reports a VS Code launch error while keeping Markdown and DB successes' {
        $script:startupOpenFailure = Get-MdhTodoPath
        $output = (mdstart 3>&1 6>&1) -join "`n"
        $output | Should Match 'Daily : (完了|警告付き完了)'
        $output | Should Match 'TODO  : 完了'
        $output | Should Match 'rebuild 完了'
        $output | Should Match 'VS Code : 表示要求 1 件、警告 1 件'
        $output | Should Match '警告付き完了'
    }

    It 'opens directory references and nested external notes in order with literal paths' {
        $quicknotes = Join-Path $TestDrive '外部 Notes O''Brien {literal}'
        $aggregate = Join-Path $script:MDHRoot 'Aggregate'
        $script:MDH_CONFIG.paths.quicknotes = $quicknotes
        $script:MDH_CONFIG.paths | Add-Member -NotePropertyName aggregate -NotePropertyValue $aggregate
        Ensure-Directory -Path (Join-Path $quicknotes 'Projects')
        Ensure-Directory -Path $aggregate
        $overview = Join-Path $quicknotes 'Overview.md'
        $project = Join-Path $quicknotes 'Projects/開発 [1].md'
        $index = Join-Path $aggregate 'index.md'
        foreach ($path in $overview, $project, $index) {
            [IO.File]::WriteAllText($path, '# Fixture')
        }
        $script:MDH_CONFIG.startup.open_files = @(
            '{QUICKNOTES}\Overview.md', '{quicknotes}/Projects/開発 [1].md',
            '{quicknotes}\Projects\..\Overview.md', '{MDH_root}', '{daily}', '{aggregate}\index.md', $index, $aggregate
        )

        (Open-MdhStartupFiles -DateText $script:startupDate) | Should Be 'Requested 6 items'
        ($script:startupOpened -join '|') |
            Should Be (@($overview, $project, $script:MDHRoot, $script:MDH_CONFIG.paths.daily, $index, $aggregate) -join '|')
    }

    It 'warns for invalid entries and continues without globbing or warning for a missing previous Daily' {
        $note = Join-Path $script:MDH_CONFIG.paths.quicknotes 'Overview.md'
        [IO.File]::WriteAllText($note, '# Fixture')
        $script:MDH_CONFIG.startup.open_files = @(
            '{unknown}\Overview.md', '{quicknotes\Overview.md', '{quicknotes}}', '{quicknotes}\missing.md',
            '', $null, 123, @('nested.md'), [pscustomobject]@{ file = 'Overview.md' },
            '{todo}\file.md', '{today_daily}\file.md', '{previous_daily}\file.md',
            '{quicknotes}\{daily}\file.md', '{MDH_root}{quicknotes}', 'prefix{quicknotes}\file.md',
            '{quicknotes}\*.md', '{previous_daily}', '{quicknotes}\Overview.md'
        )

        $result = Open-MdhStartupFiles -DateText $script:startupDate -WarningVariable warnings 3>$null
        $result | Should Be 'Requested 1 item, 16 warnings'
        $warnings.Count | Should Be 16
        @($warnings | Where-Object Message -Match '先頭に1個').Count | Should Be 3
        ($warnings.Message -join '|') | Should Match '未定義のパス参照'
        ($warnings.Message -join '|') | Should Match '不完全なパス参照'
        ($script:startupOpened -join '|') | Should Be $note
    }

    It 'distinguishes a one-element array from a string read from config.json and honors NoOpen' {
        $configPath = Join-Path $script:MDHRoot 'config.json'
        $note = Join-Path $script:MDH_CONFIG.paths.quicknotes 'Overview.md'
        [IO.File]::WriteAllText($note, '# Fixture')
        $script:MDH_CONFIG.startup.open_files = @('{quicknotes}\Overview.md')
        $script:MDH_CONFIG | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8
        $script:MDH_CONFIG = Read-MdhConfiguration -MDHRoot $script:MDHRoot -MDHConfig $configPath

        $output = (mdstart -NoOpen -SkipDb 6>&1) -join "`n"
        $output | Should Match 'VS Code : 省略（-NoOpen）'
        $script:startupOpened.Count | Should Be 0
        (Open-MdhStartupFiles -DateText $script:startupDate) | Should Be 'Requested 1 item'
        $script:startupOpened[0] | Should Be $note

        $script:MDH_CONFIG.startup.open_files = '{quicknotes}\Overview.md'
        $script:MDH_CONFIG | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8
        $script:MDH_CONFIG = Read-MdhConfiguration -MDHRoot $script:MDHRoot -MDHConfig $configPath
        (Open-MdhStartupFiles -DateText $script:startupDate 3>$null) | Should Be '0 items, 1 warning'
        $script:startupOpened.Count | Should Be 1
    }

    It 'makes no display requests for empty, null or omitted settings and warns for nonarrays' {
        $script:MDH_CONFIG.startup.open_files = @()
        (Open-MdhStartupFiles -DateText $script:startupDate) | Should Be 'Requested 0 items'
        $script:MDH_CONFIG.startup.open_files = $null
        (Open-MdhStartupFiles -DateText $script:startupDate) | Should Be 'Requested 0 items'
        $script:MDH_CONFIG.startup = [pscustomobject]@{}
        (Open-MdhStartupFiles -DateText $script:startupDate) | Should Be 'Requested 0 items'
        $script:MDH_CONFIG.PSObject.Properties.Remove('startup')
        (Open-MdhStartupFiles -DateText $script:startupDate) | Should Be 'Requested 0 items'

        foreach ($invalid in '{quicknotes}', 123, @{ path = '{quicknotes}' }) {
            $script:MDH_CONFIG | Add-Member -Force -NotePropertyName startup -NotePropertyValue @{ open_files = $invalid }
            (Open-MdhStartupFiles -DateText $script:startupDate -WarningVariable warnings 3>$null) |
                Should Be '0 items, 1 warning'
            $warnings[0].Message | Should Match '配列で指定'
        }
        $script:startupOpened.Count | Should Be 0
    }

    Context 'Daily non-terminating errors' {
        It 'stops TODO and DB even when today already exists' {
            $null = Set-TestStartupDaily -DateText $script:startupDate -Content '# Existing Daily'
            Mock Start-MdhDaily { Write-Error 'Daily write error' }

            $output = (mdstart -NoOpen 3>&1 6>&1) -join "`n"

            $output | Should Match 'Daily: Daily write error'
            $output | Should Match 'Daily : 失敗'
            $output | Should Match 'TODO  : 省略（Daily 失敗）'
            $output | Should Match 'DB    : 省略（Daily 失敗）'
            (Test-Path -LiteralPath (Get-MdhTodoPath)) | Should Be $false
            $script:startupCalls.Count | Should Be 0
        }
    }

    Context 'TODO non-terminating errors' {
        It 'reports TODO failure and stops DB after a successful Daily' {
            Mock Update-MdhTodo { Write-Error 'TODO write error' }

            $output = (mdstart -NoOpen 3>&1 6>&1) -join "`n"

            $output | Should Match 'Daily : (完了|警告付き完了)'
            $output | Should Match 'TODO: TODO write error'
            $output | Should Match 'TODO  : 失敗'
            $output | Should Match 'DB    : 省略（TODO 失敗）'
            $output | Should Match 'mdstart 2026-11-23 \| 部分失敗'
            $script:startupCalls.Count | Should Be 0
        }
    }
}

Describe 'mdstart file display' {
    It 'passes a special-character path intact through the Windows CLI wrapper' -Skip:(-not $env:MDH_TEST_PYTHON_EXECUTABLE) {
        $script:MDHRoot = $TestDrive
        $cli = Join-Path $TestDrive 'native-cli'
        $notes = Join-Path $cli '日本語 O''Brien [1] {literal} & (notes)'
        Ensure-Directory -Path $notes
        $note = Join-Path $notes '100% %MDH_TEST_CLI_MARKER%.md'
        [IO.File]::WriteAllText($note, '# Fixture')
        $log = Join-Path $cli 'argv.json'
        [IO.File]::WriteAllText((Join-Path $cli 'argv.py'),
            'import json, os, pathlib, sys; pathlib.Path(os.environ["MDH_TEST_CODE_LOG"]).write_text(json.dumps(sys.argv[1:]), encoding="utf-8")')
        [IO.File]::WriteAllLines((Join-Path $cli 'code.cmd'), @(
            '@echo off'
            'setlocal'
            '"%MDH_TEST_PYTHON_EXECUTABLE%" "%~dp0argv.py" %*'
            'exit /b %ERRORLEVEL%'
        ))
        $script:MDH_CONFIG = @{
            paths = @{ quicknotes = $notes }
            startup = @{ open_files = @('{quicknotes}\100% %MDH_TEST_CLI_MARKER%.md') }
        }
        $originalPath = $env:PATH
        $originalLog = $env:MDH_TEST_CODE_LOG
        $originalMarker = $env:MDH_TEST_CLI_MARKER
        try {
            $env:PATH = "$cli;$originalPath"
            $env:MDH_TEST_CODE_LOG = $log
            $env:MDH_TEST_CLI_MARKER = 'expanded'
            (Open-MdhStartupFiles -DateText '2026-11-23') | Should Be 'Requested 1 item'
            $arguments = Get-Content -Raw -LiteralPath $log | ConvertFrom-Json -NoEnumerate
            $arguments.Count | Should Be 2
            $arguments[0] | Should Be '--reuse-window'
            $arguments[1] | Should Be $note
        }
        finally {
            $env:PATH = $originalPath
            $env:MDH_TEST_CODE_LOG = $originalLog
            $env:MDH_TEST_CLI_MARKER = $originalMarker
        }
    }

    It 'submits multiple ordered file requests with reuse-window and resolves the configured TODO' {
        $script:MDHRoot = $TestDrive
        $todoPath = Join-Path $TestDrive 'my tasks.md'
        $notesPath = Join-Path $TestDrive 'notes file.md'
        $log = Join-Path $TestDrive 'code.log'
        [IO.File]::WriteAllText($todoPath, '# TODO')
        [IO.File]::WriteAllText($notesPath, '# Notes')
        $script:MDH_CONFIG = [pscustomobject]@{
            todo = [pscustomobject]@{ file = 'my tasks.md' }
            startup = [pscustomobject]@{ open_files = @('{todo}', './my tasks.md', 'missing.md', 'notes file.md') }
        }
        [IO.File]::WriteAllLines((Join-Path $TestDrive 'code.cmd'), @(
            '@echo off'
            'echo %~1^|%~2>> "%MDH_TEST_CODE_LOG%"'
        ))
        $originalPath = $env:PATH
        $originalLog = $env:MDH_TEST_CODE_LOG
        try {
            $env:PATH = "$TestDrive;$originalPath"
            $env:MDH_TEST_CODE_LOG = $log
            $result = Open-MdhStartupFiles -DateText '2026-11-23' 3>$null
        }
        finally {
            $env:PATH = $originalPath
            $env:MDH_TEST_CODE_LOG = $originalLog
        }
        $result | Should Be 'Requested 2 items, 1 warning'
        ($([IO.File]::ReadAllLines($log)) -join "`n") |
            Should Be "--reuse-window|$todoPath`n--reuse-window|$notesPath"
    }

    It 'warns without counting a file removed between path resolution and launch' {
        $script:MDHRoot = $TestDrive
        $script:startupVanishingFile = Join-Path $TestDrive 'vanishing.md'
        $script:startupFileChecks = 0
        [IO.File]::WriteAllText($script:startupVanishingFile, '# Temporary file')
        $script:MDH_CONFIG = [pscustomobject]@{
            startup = [pscustomobject]@{ open_files = @('vanishing.md') }
        }
        Mock Test-Path {
            $script:startupFileChecks++
            if ($script:startupFileChecks -eq 2) {
                [IO.File]::Delete($LiteralPath)
            }
            [IO.File]::Exists($LiteralPath)
        } -ParameterFilter { $LiteralPath -eq $script:startupVanishingFile }
        Mock Start-Process {}

        $warnings = @()
        $result = Open-MdhStartupFiles -DateText '2026-11-23' -WarningVariable warnings 3>$null

        $result | Should Be 'Requested 0 items, 1 warning'
        $warnings.Count | Should Be 1
        $warnings[0].Message | Should Match '起動直前.*vanishing\.md'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
        @(Open-IfExist -Path $script:startupVanishingFile 3>&1).Count | Should Be 0
    }
}

Describe 'mdstart from the production loader' {
    It 'rebuilds once, syncs the same generation and refuses a broken pointer' -Skip:(-not $env:MDH_TEST_PYTHON_EXECUTABLE) {
        $root = Join-Path $TestDrive 'startup integration'
        $scripts = Join-Path $root '40_scripts'
        $settings = Join-Path $root '50_settings'
        $package = Join-Path $scripts 'py_scripts/mdh_db'
        New-Item -ItemType Directory -Path $settings, $package -Force | Out-Null
        Copy-Item -LiteralPath $startupScripts -Destination $scripts -Recurse
        Copy-Item (Join-Path $startupScripts '../py_scripts/mdh_db/*.*') -Destination $package
        $routine = Join-Path $settings 'routine.md'
        [IO.File]::WriteAllText($routine, '- [ ] integration routine')
        @{
            paths = @{ MDH_root = '' }
            daily = @{ template = [IO.Path]::GetFullPath($startupTemplate); update_schedule = $false }
            todo = @{ routine_file = $routine }
            db = @{ python = $env:MDH_TEST_PYTHON_EXECUTABLE; store_dir = 'index' }
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $settings 'config.json') -Encoding utf8
        . (Join-Path $scripts 'pwsh_scripts/mdh.ps1')

        $first = (mdstart -NoOpen 3>&1 6>&1) -join "`n"
        $first | Should Match 'rebuild 完了'
        $pointer = Join-Path $root 'index/active'
        $generation = [IO.File]::ReadAllText($pointer)
        $second = (mdstart -NoOpen 3>&1 6>&1) -join "`n"
        $second | Should Match 'sync 完了'
        [IO.File]::ReadAllText($pointer) | Should Be $generation

        [IO.File]::WriteAllText($pointer, 'broken')
        $third = (mdstart -NoOpen 3>&1 6>&1) -join "`n"
        $third | Should Match 'status 失敗'
        $third | Should Match 'ACTIVE_DATABASE_ERROR'
        [IO.File]::ReadAllText($pointer) | Should Be 'broken'
        @(Get-ChildItem (Join-Path $root 'index') -Filter 'db-*.sqlite').Count | Should Be 1
    }
}
