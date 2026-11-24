. (Join-Path $PSScriptRoot '..\..\40_scripts\pwsh_scripts\mdh_common.ps1')
. (Join-Path $PSScriptRoot '..\..\40_scripts\pwsh_scripts\mdh_daily.ps1')

function Set-TestMdhDailyFile {
    param(
        [Parameter(Mandatory)]
        [string]$DateText,

        [Parameter(Mandatory)]
        [string]$Content,

        [switch]$Utf8Bom
    )

    $path = Get-MdhDailyPath -DateText $DateText
    Ensure-Directory -Path (Split-Path -Parent $path)
    [System.IO.File]::WriteAllText(
        $path,
        $Content,
        [System.Text.UTF8Encoding]::new($Utf8Bom.IsPresent)
    )
    return $path
}

function Get-TestMdhDailyContent {
    param([Parameter(Mandatory)][string]$Appointments)

    return @"
---
date: 2026-01-02
---

[← 2026-01-01](2026-01-01.md)

# 🏷️ 作業ログ
# 📅 今日の予定
### 自動取得
<!-- MDH:APPOINTMENTS:START -->
$Appointments
<!-- MDH:APPOINTMENTS:END -->
### 手入力の予定・メモ
- 手入力予定
- 手入力メモ

# ✅ やったこと
- 手書き本文を維持する
"@
}

Describe 'MDH daily functions' {
    BeforeEach {
        $testRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $dailyRoot = Join-Path $testRoot '01_Daily'
        $templatePath = Join-Path $testRoot 'mdtoday.md'
        Ensure-Directory -Path $dailyRoot
        [System.IO.File]::WriteAllText(
            $templatePath,
            @'
---
date: {{DATE}}
---

{{NAVIGATION}}

# 🏷️ 作業ログ：{{DATE}}（{{DOW}}）
# 📅 今日の予定
### 自動取得
<!-- MDH:APPOINTMENTS:START -->
{{APPOINTMENTS}}
<!-- MDH:APPOINTMENTS:END -->

### 手入力の予定・メモ
-

# ✅ やったこと
- 手書き内容
'@,
            [System.Text.UTF8Encoding]::new($false)
        )

        $script:MDHRoot = $testRoot
        $script:MDH_CONFIG = [pscustomobject]@{
            paths = [pscustomobject]@{
                daily = $dailyRoot
            }
            daily = [pscustomobject]@{
                template = $templatePath
                update_links = $true
                update_schedule = $true
            }
        }
    }

    It 'creates new dailies through daily and mdtoday entry points' {
        Mock Open-IfExist {}
        Mock Get-MdhDailyAppointments {
            [pscustomobject]@{
                Status = 'Unavailable'
                Appointments = @()
                Message = '予定取得未実装'
            }
        }

        daily '2026-01-02'
        $specifiedPath = Get-MdhDailyPath -DateText '2026-01-02'
        (Test-Path -LiteralPath $specifiedPath) | Should Be $true
        $bytes = [System.IO.File]::ReadAllBytes($specifiedPath)
        ($bytes[0..2] -join ',') | Should Be '239,187,191'
        [System.IO.File]::ReadAllText($specifiedPath, [System.Text.Encoding]::UTF8) |
            Should Not Match '- 予定なし'

        daily
        (Test-Path -LiteralPath (Get-MdhDailyPath)) | Should Be $true
        mdtoday -DateText '2026-01-03' -Open
        (Test-Path -LiteralPath (Get-MdhDailyPath -DateText '2026-01-03')) | Should Be $true
    }

    It 'creates the path for today and a specified date under the configured daily root' {
        $today = (Get-Date).ToString('yyyy-MM-dd')
        (Get-MdhDailyPath) | Should Be (Join-Path $script:MDH_CONFIG.paths.daily "$($today.Substring(0, 4))\$($today.Substring(0, 7))\$today.md")
        (Get-MdhDailyPath -DateText '2026-02-03') | Should Be (Join-Path $script:MDH_CONFIG.paths.daily '2026\2026-02\2026-02-03.md')
    }

    It 'finds the latest valid daily date across a year boundary' {
        Set-TestMdhDailyFile -DateText '2025-12-31' -Content 'log'
        Ensure-Directory -Path (Join-Path $script:MDH_CONFIG.paths.daily 'invalid')
        [System.IO.File]::WriteAllText(
            (Join-Path $script:MDH_CONFIG.paths.daily 'invalid\2025-99-99.md'),
            'not a date'
        )

        (Get-MdhLastDailyDate -BeforeDate '2026-01-01') | Should Be '2025-12-31'
    }

    It 'selects the previous existing daily through daily -Prev' {
        Mock Open-IfExist {}
        Set-TestMdhDailyFile -DateText '2025-12-31' -Content 'previous'
        Set-TestMdhDailyFile -DateText '2026-01-01' -Content 'reference'

        daily -DateText '2026-01-02' -Prev

        Assert-MockCalled Open-IfExist -Times 1 -ParameterFilter {
            $Path -eq (Get-MdhDailyPath -DateText '2026-01-01')
        }
    }

    It 'returns no previous date when the daily directory contains no logs' {
        (Get-MdhLastDailyDate -BeforeDate '2026-01-01') | Should Be $null
    }

    Context 'Bidirectional Daily navigation' {
        BeforeEach {
            $script:MDH_CONFIG.daily.template = Join-Path $PSScriptRoot '../../50_settings/templates/DailyTemplate.md'
            $script:MDH_CONFIG.daily.update_schedule = $false
            Mock Open-IfExist {}
            Mock Get-MdhDailyAppointments { [pscustomobject]@{ Status = 'Available'; Appointments = @() } }
        }

        It 'links the latest existing Daily to the new Daily across a date gap' {
            $body = "# 📅 今日の予定`n- 手入力予定`n`n# 🤖 自動入力`n## done`n- [TODO 2026-01-02] 作業: 維持"
            $header = "<!-- MDH:NAVIGATION:START -->`n<!-- MDH:NAVIGATION:END -->`n"
            $previous = Set-TestMdhDailyFile -DateText '2026-01-02' -Content ($header + $body) -Utf8Bom

            daily '2026-01-06'

            $expected = "[→ 2026-01-06](2026-01-06.md)`n"
            [IO.File]::ReadAllText($previous) | Should Be ($expected + $body)
            ([IO.File]::ReadAllBytes($previous)[0..2] -join ',') | Should Be '239,187,191'
            [IO.File]::ReadAllText((Get-MdhDailyPath -DateText '2026-01-06')) |
                Should Match '\[← 2026-01-02\]\(2026-01-02\.md\)'
        }

        It 'inserts between existing Dailies, keeps outer links, and is idempotent' {
            foreach ($day in '2026-01-01', '2026-01-03', '2026-01-07', '2026-01-10', '2026-01-05') {
                daily $day
            }
            $previous = Get-MdhDailyPath -DateText '2026-01-03'
            $target = Get-MdhDailyPath -DateText '2026-01-05'
            $next = Get-MdhDailyPath -DateText '2026-01-07'
            [IO.File]::ReadAllText($previous) | Should Match '\[← 2026-01-01\].*\| \[→ 2026-01-05\]'
            [IO.File]::ReadAllText($target) | Should Match '\[← 2026-01-03\].*\| \[→ 2026-01-07\]'
            [IO.File]::ReadAllText($next) | Should Match '\[← 2026-01-05\].*\| \[→ 2026-01-10\]'
            $hashes = (Get-FileHash -LiteralPath $previous, $target, $next).Hash -join ','
            daily -DateText '2026-01-06' -Prev
            ((Get-FileHash -LiteralPath $previous, $target, $next).Hash -join ',') | Should Be $hashes
        }

        It 'manages a hand-written canonical link in the neighbor header' {
            $header = "---`ndate: 2026-01-02`n---`n`n"
            $body = "`n# 本文`n[手入力](notes.md)"
            $previous = Set-TestMdhDailyFile -DateText '2026-01-02' `
                -Content "$header[→ 2026-01-10](2026-01-10.md)`n$body"

            daily '2026-01-05'

            [IO.File]::ReadAllText($previous) | Should BeExactly "$header[→ 2026-01-05](2026-01-05.md)`n$body"
        }

        It 'returns a warning record and preserves a neighbor with an unidentifiable link' {
            $text = "[→ 2026-01-10](2026-01-11.md)`r`n`r`n# 本文"
            $previous = Set-TestMdhDailyFile -DateText '2026-01-02' -Content $text -Utf8Bom
            $hash = (Get-FileHash -LiteralPath $previous).Hash

            $warning = @(daily '2026-01-05' -WarningAction Continue 3>&1)

            $warning.Count | Should Be 1
            ($warning[0] -is [System.Management.Automation.WarningRecord]) | Should Be $true
            $warning[0].Message | Should Match '2026-01-02 のナビゲーション行を安全に識別できない'
            (Get-FileHash -LiteralPath $previous).Hash | Should Be $hash
            (Test-Path -LiteralPath (Get-MdhDailyPath -DateText '2026-01-05') -PathType Leaf) | Should Be $true
        }

        It 'warns for malformed neighbor markers and keeps that file intact' {
            $bad = "<!-- MDH:NAVIGATION:START -->`n手入力`n# 本文"
            $previous = Set-TestMdhDailyFile -DateText '2026-01-01' -Content $bad
            $output = (daily '2026-01-05' 3>&1) -join "`n"
            $output | Should Match '2026-01-01 の旧ナビゲーション領域'
            [IO.File]::ReadAllText($previous) | Should Be $bad
        }

        It 'leaves existing Daily links alone when update_links is false' {
            $header = "<!-- MDH:NAVIGATION:START -->`n<!-- MDH:NAVIGATION:END -->`n# 本文"
            $previous = Set-TestMdhDailyFile -DateText '2026-01-01' -Content $header
            $next = Set-TestMdhDailyFile -DateText '2026-01-10' -Content $header
            $script:MDH_CONFIG.daily.update_links = $false
            daily '2026-01-05'
            daily '2026-01-10'
            [IO.File]::ReadAllText($previous) | Should Be $header
            [IO.File]::ReadAllText($next) | Should Be $header
        }

        It 'reports a locked neighbor and retains the already-created target' {
            $header = "<!-- MDH:NAVIGATION:START -->`n<!-- MDH:NAVIGATION:END -->`n# 本文"
            $previous = Set-TestMdhDailyFile -DateText '2026-01-01' -Content $header
            $lock = [IO.File]::Open($previous, 'Open', 'ReadWrite', 'None')
            $failure = $null
            try {
                daily '2026-01-05'
            }
            catch {
                $failure = $_.Exception.Message
            }
            finally {
                $lock.Dispose()
            }
            $failure | Should Match '隣接日報 2026-01-01'
            (Test-Path -LiteralPath (Get-MdhDailyPath -DateText '2026-01-05') -PathType Leaf) | Should Be $true
            [IO.File]::ReadAllText($previous) | Should Be $header
            daily '2026-01-05'
            [IO.File]::ReadAllText($previous) | Should BeExactly "[→ 2026-01-05](2026-01-05.md)`n# 本文"
        }

        It 'keeps the first shipped Daily linkable across month and year boundaries' {
            daily '2025-12-30'
            daily '2026-02-02'
            $previous = Get-MdhDailyPath -DateText '2025-12-30'
            $next = Get-MdhDailyPath -DateText '2026-02-02'
            [IO.File]::ReadAllText($previous) | Should Match '\[→ 2026-02-02\]\(\.\./\.\./2026/2026-02/2026-02-02\.md\)'
            [IO.File]::ReadAllText($next) | Should Match '\[← 2025-12-30\]\(\.\./\.\./2025/2025-12/2025-12-30\.md\)'
            Move-Item -LiteralPath $next -Destination (Join-Path $TestDrive 'moved.md')
            daily '2025-12-30'
            [IO.File]::ReadAllText($previous) | Should Not Match '\[→ '
        }
    }

    It 'reports a missing daily root rather than treating it as an empty log history' {
        $script:MDH_CONFIG.paths.daily = Join-Path $script:MDHRoot 'missing-dailies'

        $rootFailureReported = $false
        try {
            Get-MdhLastDailyDate -BeforeDate '2026-01-01'
        }
        catch {
            $rootFailureReported = $true
        }
        $rootFailureReported | Should Be $true
    }

    It 'rejects malformed and impossible dates' {
        $invalidDateRejected = $false
        try {
            Get-MdhDailyPath -DateText '2026-02-30'
        }
        catch {
            $invalidDateRejected = $true
        }
        $invalidDateRejected | Should Be $true

        $malformedDateRejected = $false
        try {
            Resolve-MdhDailyDate -DateText 'not-a-date'
        }
        catch {
            $malformedDateRejected = $true
        }
        $malformedDateRejected | Should Be $true
    }

    It 'generates a new daily with date, weekday, links, and successful appointments' {
        $script:MDH_CONFIG.daily.template = 'mdtoday.md'
        $targetDate = [datetime]::ParseExact('2026-01-01', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
        $content = New-MdhDailyContent `
            -TargetDate $targetDate `
            -PreviousDate '2025-12-31' `
            -NextDate '2026-01-02' `
            -Appointments @('- 09:00 予定')

        $content | Should Match 'date: 2026-01-01'
        $content | Should Match '2026-01-01（木）'
        $content | Should Match '\[← 2025-12-31\]\(\.\./\.\./2025/2025-12/2025-12-31\.md\)'
        $content | Should Match '\[→ 2026-01-02\]\(2026-01-02\.md\)'
        $content | Should Match '- 09:00 予定'
        $content | Should Match '<!-- MDH:APPOINTMENTS:START -->'
    }

    It 'leaves an unavailable new appointment result blank rather than claiming no events' {
        Mock Open-IfExist {}
        Mock Get-MdhDailyAppointments {
            [pscustomobject]@{
                Status = 'Unavailable'
                Appointments = @()
                Message = '予定取得未実装'
            }
        }

        Update-MdhDailyFile -TargetDate ([datetime]::ParseExact('2026-01-02', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture))

        $content = [System.IO.File]::ReadAllText((Get-MdhDailyPath -DateText '2026-01-02'))
        [regex]::IsMatch($content, '<!-- MDH:APPOINTMENTS:START -->\r?\n<!-- MDH:APPOINTMENTS:END -->') | Should Be $true
        $content | Should Not Match '予定なし'
    }

    It 'records no events only after a successful empty appointment result' {
        Mock Open-IfExist {}
        Mock Get-MdhDailyAppointments {
            [pscustomobject]@{
                Status = 'Available'
                Appointments = @()
                Message = $null
            }
        }

        Update-MdhDailyFile -TargetDate ([datetime]::ParseExact('2026-01-02', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture))

        $content = [System.IO.File]::ReadAllText((Get-MdhDailyPath -DateText '2026-01-02'))
        $content | Should Match '- 予定なし'
    }

    It 'preserves hand-entered appointments when appointment retrieval is unavailable or fails' {
        Mock Open-IfExist {}
        $script:MDH_CONFIG.daily.update_links = $false
        $path = Set-TestMdhDailyFile -DateText '2026-01-02' -Content @'
# 📅 今日の予定
- 手入力予定
- 予定の補足メモ

# ✅ やったこと
- 本文
'@
        $before = [System.IO.File]::ReadAllBytes($path)
        Mock Get-MdhDailyAppointments {
            [pscustomobject]@{
                Status = 'Unavailable'
                Appointments = @()
                Message = '予定取得未実装'
            }
        }

        Update-MdhDailyFile -TargetDate ([datetime]::ParseExact('2026-01-02', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture))
        [System.IO.File]::ReadAllBytes($path) | Should Be $before

        Mock Get-MdhDailyAppointments { throw 'appointment failure' }
        Update-MdhDailyFile -TargetDate ([datetime]::ParseExact('2026-01-02', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture))
        [System.IO.File]::ReadAllBytes($path) | Should Be $before
    }

    It 'does not treat a malformed successful appointment result as an empty schedule' {
        Mock Open-IfExist {}
        $script:MDH_CONFIG.daily.update_links = $false
        $path = Set-TestMdhDailyFile -DateText '2026-01-02' -Content @'
# 📅 今日の予定
- 手入力予定
'@
        $before = [System.IO.File]::ReadAllBytes($path)
        Mock Get-MdhDailyAppointments {
            [pscustomobject]@{
                Status = 'Available'
                Message = 'invalid provider response'
            }
        }

        Update-MdhDailyFile -TargetDate ([datetime]::ParseExact('2026-01-02', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture))

        [System.IO.File]::ReadAllBytes($path) | Should Be $before
    }

    It 'preserves a manual appointment section when a provider succeeds but no managed region exists' {
        Mock Open-IfExist {}
        $script:MDH_CONFIG.daily.update_links = $false
        $path = Set-TestMdhDailyFile -DateText '2026-01-02' -Content @'
# 📅 今日の予定
- 手入力予定
- 手入力メモ
'@
        $before = [System.IO.File]::ReadAllBytes($path)
        Mock Get-MdhDailyAppointments {
            [pscustomobject]@{
                Status = 'Available'
                Appointments = @('- 09:00 会議')
                Message = $null
            }
        }
        $warnings = @()

        Update-MdhDailyFile `
            -TargetDate ([datetime]::ParseExact('2026-01-02', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)) `
            -WarningVariable warnings

        [System.IO.File]::ReadAllBytes($path) | Should Be $before
        $warnings.Count | Should Be 1
    }

    It 'updates only the managed appointment region and preserves surrounding content' {
        $content = Get-TestMdhDailyContent -Appointments '- old managed appointment'
        Mock Get-MdhDailyAppointments {
            [pscustomobject]@{
                Status = 'Available'
                Appointments = @('- 09:00 会議')
                Message = $null
            }
        }
        Mock Open-IfExist {}
        $path = Set-TestMdhDailyFile -DateText '2026-01-02' -Content $content
        $script:MDH_CONFIG.daily.update_links = $false

        Update-MdhDailyFile -TargetDate ([datetime]::ParseExact('2026-01-02', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture))
        $updated = [System.IO.File]::ReadAllText($path)

        $updated | Should Match '- 09:00 会議'
        $updated | Should Match '- 手入力予定'
        $updated | Should Match '- 手入力メモ'
        $updated | Should Match '- 手書き本文を維持する'
        $updated | Should Match '# 🏷️ 作業ログ'
    }

    It 'does not update appointment content when the managed region is missing or ambiguous' {
        $contentWithoutMarkers = "# 📅 今日の予定`n- 手入力"
        $warnings = @()
        $unchanged = Update-MdhDailyAppointments `
            -Content $contentWithoutMarkers `
            -Appointments @('- replacement') `
            -WarningVariable warnings
        $unchanged | Should Be $contentWithoutMarkers
        $warnings.Count | Should Be 1

        $duplicateHeadings = Get-TestMdhDailyContent -Appointments '- managed'
        $duplicateHeadings += "`n# 📅 今日の予定`n- another section"
        $warnings = @()
        $unchanged = Update-MdhDailyAppointments `
            -Content $duplicateHeadings `
            -Appointments @('- replacement') `
            -WarningVariable warnings
        $unchanged | Should Be $duplicateHeadings
        $warnings.Count | Should Be 1
    }

    It 'keeps repeated navigation and managed appointment updates idempotent' {
        $content = Get-TestMdhDailyContent -Appointments '- old managed appointment'
        $targetDate = [datetime]::ParseExact('2026-01-02', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
        $once = Update-MdhDailyNavigation -Content $content -TargetDate $targetDate -PreviousDate '2026-01-01'
        $once = Update-MdhDailyAppointments -Content $once -Appointments @('- 09:00 予定')
        $twice = Update-MdhDailyNavigation -Content $once -TargetDate $targetDate -PreviousDate '2026-01-01'
        $twice = Update-MdhDailyAppointments -Content $twice -Appointments @('- 09:00 予定')

        ([regex]::Matches($twice, '\[← 2026-01-01\]')).Count | Should Be 1
        ([regex]::Matches($twice, '- 09:00 予定')).Count | Should Be 1
        $twice | Should Match '- 手書き本文を維持する'
    }

    It 'preserves manual navigation when more than one generated navigation line exists' {
        $content = "[← 2026-01-01](one.md)`n[→ 2026-01-03](three.md)`n# Heading"
        $warnings = @()
        $updated = Update-MdhDailyNavigation `
            -Content $content `
            -TargetDate ([datetime]::ParseExact('2026-01-02', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)) `
            -PreviousDate '2026-01-01' `
            -WarningVariable warnings

        $updated | Should Be $content
        $warnings.Count | Should Be 1
    }

    It 'respects link and appointment update settings independently' {
        Mock Open-IfExist {}
        Mock Get-MdhDailyAppointments {
            [pscustomobject]@{
                Status = 'Available'
                Appointments = @('- replacement appointment')
                Message = $null
            }
        }

        $content = Get-TestMdhDailyContent -Appointments '- hand-entered appointment'
        $path = Set-TestMdhDailyFile -DateText '2026-01-02' -Content $content
        $script:MDH_CONFIG.daily.update_links = $false
        Update-MdhDailyFile -TargetDate ([datetime]::ParseExact('2026-01-02', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture))
        $updated = [System.IO.File]::ReadAllText($path)
        $updated | Should Match '\[← 2026-01-01\]'
        $updated | Should Match '- replacement appointment'

        $script:MDH_CONFIG.daily.update_links = $true
        $script:MDH_CONFIG.daily.update_schedule = $false
        Set-TestMdhDailyFile -DateText '2026-01-02' -Content 'previous'
        $path = Set-TestMdhDailyFile -DateText '2026-01-03' -Content (Get-TestMdhDailyContent -Appointments '- hand-entered appointment')
        Update-MdhDailyFile `
            -TargetDate ([datetime]::ParseExact('2026-01-03', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)) `
            -PreviousDate '2026-01-02'
        $updated = [System.IO.File]::ReadAllText($path)
        $updated | Should Match '- hand-entered appointment'
        $updated | Should Match '\[← 2026-01-02\]'
        Assert-MockCalled Get-MdhDailyAppointments -Times 1
    }

    It 'does not create a daily when the template is missing or malformed' {
        $script:MDH_CONFIG.daily.template = Join-Path $script:MDHRoot 'missing-template.md'
        $missingTemplateRejected = $false
        try {
            Update-MdhDailyFile -TargetDate ([datetime]::ParseExact('2026-01-02', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture))
        }
        catch {
            $missingTemplateRejected = $true
        }
        $missingTemplateRejected | Should Be $true
        (Test-Path -LiteralPath (Get-MdhDailyPath -DateText '2026-01-02')) | Should Be $false

        $invalidTemplatePath = Join-Path $script:MDHRoot 'invalid-template.md'
        [System.IO.File]::WriteAllText($invalidTemplatePath, '# Missing placeholders')
        $script:MDH_CONFIG.daily.template = $invalidTemplatePath
        $invalidTemplateRejected = $false
        try {
            Update-MdhDailyFile -TargetDate ([datetime]::ParseExact('2026-01-02', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture))
        }
        catch {
            $invalidTemplateRejected = $true
        }
        $invalidTemplateRejected | Should Be $true
        (Test-Path -LiteralPath (Get-MdhDailyPath -DateText '2026-01-02')) | Should Be $false

        [System.IO.File]::WriteAllText(
            $invalidTemplatePath,
            "date: {{DATE}}`n{{DOW}}`n{{NAVIGATION}}`n{{APPOINTMENTS}}"
        )
        $script:MDH_CONFIG.daily.template = $invalidTemplatePath
        $invalidMarkersRejected = $false
        try {
            Update-MdhDailyFile -TargetDate ([datetime]::ParseExact('2026-01-02', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture))
        }
        catch {
            $invalidMarkersRejected = $true
        }
        $invalidMarkersRejected | Should Be $true
        (Test-Path -LiteralPath (Get-MdhDailyPath -DateText '2026-01-02')) | Should Be $false

        [System.IO.File]::WriteAllText(
            $invalidTemplatePath,
            "# 📅 今日の予定`n<!-- MDH:APPOINTMENTS:START --> {{APPOINTMENTS}} <!-- MDH:APPOINTMENTS:END -->"
        )
        $script:MDH_CONFIG.daily.template = $invalidTemplatePath
        $misplacedMarkersRejected = $false
        try {
            Update-MdhDailyFile -TargetDate ([datetime]::ParseExact('2026-01-02', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture))
        }
        catch {
            $misplacedMarkersRejected = $true
        }
        $misplacedMarkersRejected | Should Be $true
        (Test-Path -LiteralPath (Get-MdhDailyPath -DateText '2026-01-02')) | Should Be $false
    }

    It 'preserves an existing daily when reading fails because the file is locked' {
        Mock Open-IfExist {}
        $script:MDH_CONFIG.daily.update_links = $false
        $path = Set-TestMdhDailyFile -DateText '2026-01-02' -Content (Get-TestMdhDailyContent -Appointments '- manual')
        $before = [System.IO.File]::ReadAllBytes($path)
        $failureReported = $false
        $lock = [System.IO.File]::Open(
            $path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::None
        )
        try {
            Update-MdhDailyFile -TargetDate ([datetime]::ParseExact('2026-01-02', 'yyyy-MM-dd', [cultureinfo]::InvariantCulture))
        }
        catch {
            $failureReported = $true
        }
        finally {
            $lock.Dispose()
        }
        $failureReported | Should Be $true
        [System.IO.File]::ReadAllBytes($path) | Should Be $before
    }

    It 'preserves an existing daily and cleans the temporary file when replacement fails' {
        $path = Set-TestMdhDailyFile -DateText '2026-01-02' -Content (Get-TestMdhDailyContent -Appointments '- manual')
        $expectedHash = (Read-MdhDailyFile -Path $path).Hash
        $lock = [System.IO.File]::Open(
            $path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::None
        )

        $failureReported = $false
        try {
            Write-MdhDailyFile -Path $path -Content 'replacement' -ExpectedHash $expectedHash
        }
        catch {
            $failureReported = $true
        }
        finally {
            $lock.Dispose()
        }
        $failureReported | Should Be $true
        [System.IO.File]::ReadAllText($path) | Should Match '手書き本文を維持する'
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter '.*.tmp' -File).Count | Should Be 0
    }

    It 'serializes competing saves from separate PowerShell processes' {
        $path = Set-TestMdhDailyFile -DateText '2026-01-02' -Content 'original'
        $hash = (Read-MdhTextFile -Path $path).Hash
        $common = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../40_scripts/pwsh_scripts/mdh_common.ps1'))
        $mutex = [Threading.Mutex]::new($false, (Get-MdhMarkdownMutexName -Path $path))
        $owned = $mutex.WaitOne()
        $jobs = @()
        try {
            foreach ($value in 'first', 'second') {
                $jobs += Start-Job -ArgumentList $common, $path, $hash, $value -ScriptBlock {
                    param($common, $path, $hash, $value)
                    . $common
                    'ready'
                    try {
                        Write-MdhTextFile -Path $path -Content $value -ExpectedHash $hash
                        "saved:$value"
                    }
                    catch { "rejected:$($_.Exception.Message)" }
                }
            }
            $deadline = [datetime]::UtcNow.AddSeconds(10)
            do {
                $ready = @(Receive-Job -Job $jobs -Keep | Where-Object { $_ -eq 'ready' }).Count
                if ($ready -lt 2) { Start-Sleep -Milliseconds 50 }
            } until ($ready -eq 2 -or [datetime]::UtcNow -ge $deadline)
            $ready | Should Be 2
            [IO.File]::ReadAllText($path) | Should Be 'original'
            @($jobs | Where-Object State -eq 'Completed').Count | Should Be 0
            $mutex.ReleaseMutex()
            $owned = $false
            $null = Wait-Job -Job $jobs -Timeout 20
            $outcomes = @(Receive-Job -Job $jobs)
            @($outcomes | Where-Object { $_ -like 'saved:*' }).Count | Should Be 1
            @($outcomes | Where-Object { $_ -like 'rejected:*上書きを中止*' }).Count | Should Be 1
            ('saved:' + [IO.File]::ReadAllText($path)) | Should Be ($outcomes | Where-Object { $_ -like 'saved:*' })
        }
        finally {
            if ($owned) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
            if ($jobs) { Remove-Job -Job $jobs -Force }
        }
    }

    It 'does not overwrite a concurrent edit and removes the temporary file' {
        $path = Set-TestMdhDailyFile -DateText '2026-01-02' -Content 'original'
        $expectedHash = (Read-MdhDailyFile -Path $path).Hash
        [System.IO.File]::WriteAllText($path, 'concurrent edit')

        $failureReported = $false
        try {
            Write-MdhDailyFile -Path $path -Content 'stale update' -ExpectedHash $expectedHash
        }
        catch {
            $failureReported = $true
        }
        $failureReported | Should Be $true
        [System.IO.File]::ReadAllText($path) | Should Be 'concurrent edit'
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter '.*.tmp' -File).Count | Should Be 0
    }

    It 'does not overwrite an existing file during new-file creation' {
        $path = Set-TestMdhDailyFile -DateText '2026-01-02' -Content 'preserve me'

        $failureReported = $false
        try {
            Write-MdhDailyFile -Path $path -Content 'replacement' -CreateNew -Utf8Bom
        }
        catch {
            $failureReported = $true
        }
        $failureReported | Should Be $true
        [System.IO.File]::ReadAllText($path) | Should Be 'preserve me'
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter '.*.tmp' -File).Count | Should Be 0
    }

    It 'preserves LF or CRLF and the existing UTF-8 BOM during a real update' {
        Mock Open-IfExist {}
        Mock Get-MdhDailyAppointments {
            [pscustomobject]@{
                Status = 'Available'
                Appointments = @('- 09:00 会議')
                Message = $null
            }
        }
        $script:MDH_CONFIG.daily.update_links = $false
        $dateIndex = 1
        foreach ($newline in @("`n", "`r`n")) {
            foreach ($hasBom in @($false, $true)) {
                $dateText = '2026-01-0{0}' -f $dateIndex
                $dateIndex++
                $content = @(
                    '# 📅 今日の予定'
                    '<!-- MDH:APPOINTMENTS:START -->'
                    '- old'
                    '<!-- MDH:APPOINTMENTS:END -->'
                    '# ✅ やったこと'
                    '- 手書き本文'
                ) -join $newline
                $path = Set-TestMdhDailyFile -DateText $dateText -Content $content -Utf8Bom:$hasBom

                Update-MdhDailyFile -TargetDate ([datetime]::ParseExact($dateText, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture))

                $bytes = [System.IO.File]::ReadAllBytes($path)
                $actualBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
                    $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
                $actualBom | Should Be $hasBom
                $updated = [System.Text.UTF8Encoding]::new($false, $true).GetString(
                    $bytes,
                    $(if ($actualBom) { 3 } else { 0 }),
                    $bytes.Length - $(if ($actualBom) { 3 } else { 0 })
                )
                $updated | Should Match '- 09:00 会議'
                if ($newline -eq "`n") {
                    $updated | Should Not Match "`r"
                }
                else {
                    $updated | Should Not Match '(?<!\r)\n'
                }
            }
        }
    }

    It 'generates the shipped template and keeps the managed navigation and schedule separate' {
        $script:MDH_CONFIG.daily.template = Join-Path $PSScriptRoot '..\..\50_settings\templates\DailyTemplate.md'
        Mock Open-IfExist {}

        Mock Get-MdhDailyAppointments { [pscustomobject]@{ Status = 'Unavailable'; Message = '予定取得不能' } }

        daily -DateText '2026-11-22'

        $path = Get-MdhDailyPath -DateText '2026-11-22'
        $file = Read-MdhTextFile -Path $path
        $file.HasUtf8Bom | Should Be $true
        $file.Content | Should Match 'date: 2026-11-22\r?\ntitle: ""\r?\ntags: \[\]\r?\nprojects: \[\]'
        $file.Content | Should Match '# 🏷️ 作業ログ：2026-11-22（日）'
        $file.Content | Should Not Match 'MDH:NAVIGATION:|\[(?:←|→) '
        $file.Content | Should Match '## 📅 今日の予定\r?\n<!-- MDH:APPOINTMENTS:START -->\r?\n<!-- MDH:APPOINTMENTS:END -->\r?\n\r?\n# ✅ やったこと'
        $file.Content | Should Match '# 🤖 自動入力\r?\n## done'

        $manual = $file.Content.Replace('<!-- MDH:APPOINTMENTS:END -->', "<!-- MDH:APPOINTMENTS:END -->`n- 手入力")
        [IO.File]::WriteAllText($path, $manual, [Text.UTF8Encoding]::new($true))
        Set-TestMdhDailyFile -DateText '2026-11-01' -Content 'previous' | Out-Null
        daily -DateText '2026-11-22'
        $withLink = (Read-MdhTextFile -Path $path).Content
        $withLink | Should Match '(?m)^\[← 2026-11-01\]\(2026-11-01\.md\)\r?$'
        $withLink | Should Not Match 'MDH:NAVIGATION:'
        $withLink | Should Match '<!-- MDH:APPOINTMENTS:END -->\r?\n- 手入力'
        daily -DateText '2026-11-22'
        (Read-MdhTextFile -Path $path).Content | Should BeExactly $withLink
        Remove-Item -LiteralPath (Get-MdhDailyPath -DateText '2026-11-01')
        daily -DateText '2026-11-22'
        $updated = Read-MdhTextFile -Path $path
        $updated.Content | Should BeExactly $manual
        $updated.HasUtf8Bom | Should Be $true
    }

    It 'preserves manual appointments in both daily structures and ignores fenced examples' {
        $start = '<!-- MDH:APPOINTMENTS:START -->'
        $end = '<!-- MDH:APPOINTMENTS:END -->'
        $prefixes = @(
            "# 作業ログ`n## 📅 今日の予定`n"
            "# 📅 今日の予定`n## 自動取得`n"
        )
        foreach ($prefix in $prefixes) {
            $suffix = "`n## 手動入力`n- 手入力`n# ✅ やったこと`n~~~markdown`n$start`n$end`n~~~"
            $content = "$prefix$start`n- 旧予定`n$end$suffix"
            $updated = Update-MdhDailyAppointments -Content $content -Appointments @('- 09:00 更新')
            $updated | Should BeExactly "$prefix$start`n- 09:00 更新`n$end$suffix"
        }
        $unsafe = "# 📅 今日の予定`n## 自動取得`n$start`n## 手動入力`n- 手入力`n$end"
        (Update-MdhDailyAppointments -Content $unsafe -Appointments @('- 更新')) | Should BeExactly $unsafe
    }

    It 'preserves navigation when a managed block is incomplete, duplicated or outside the header' {
        $start = '<!-- MDH:NAVIGATION:START -->'
        $end = '<!-- MDH:NAVIGATION:END -->'
        $targetDate = [datetime]::new(2026, 11, 22)
        $cases = @(
            "$start`n# 作業ログ"
            "$end`n$start`n# 作業ログ"
            "$start`n$start`n$end`n# 作業ログ"
            "$start`n[手入力](notes.md)`n$end`n# 作業ログ"
            "# 作業ログ`n$start`n$end"
            "# 作業ログ`n~~~markdown`n$start`n$end`n~~~"
            "# 作業ログ`n# 🤖 自動入力`n## done"
        )
        foreach ($content in $cases) {
            $updated = Update-MdhDailyNavigation -Content $content -TargetDate $targetDate -PreviousDate '2026-11-01'
            $updated | Should BeExactly $content
        }
    }

    It 'preserves ambiguous links and only updates the canonical header line' {
        $date = [datetime]::new(2026, 11, 22)
        $canonical = '[← 2026-11-01](2026-11-01.md)'
        $examples = "~~~markdown`n$canonical`n~~~`n[手入力](notes.md)`n# 作業ログ`n$canonical"
        $frontMatter = "---`ntext: |`n$canonical`n---`n`n"
        $source = "$frontMatter$canonical`n$examples"
        $result = Update-MdhDailyNavigation -Content $source -TargetDate $date -PreviousDate '2026-11-20'
        $result | Should BeExactly "$frontMatter[← 2026-11-20](2026-11-20.md)`n$examples"
        foreach ($invalid in @(
            '[← 2026-11-01](2026-11-02.md)'
            '[← 2026-11-01](elsewhere/2026-11-01.md)'
            '[← 2026-11-24](2026-11-24.md)'
            '[→ 2026-11-31](2026-11-31.md)'
            '[手入力](2026-11-01.md)'
            "$canonical`n$canonical"
            "$canonical`n---"
        )) {
            $text = "$invalid`n# 作業ログ"
            $warnings = @()
            $result = Update-MdhDailyNavigation -Content $text -TargetDate $date -PreviousDate '2026-11-20' -WarningVariable warnings
            $result | Should BeExactly $text
            $warnings.Count | Should Be 1
        }
    }

    It 'migrates a populated legacy block and preserves the surrounding Markdown' {
        $start = '<!-- MDH:NAVIGATION:START -->'
        $end = '<!-- MDH:NAVIGATION:END -->'
        $header = "---`r`ndate: 2026-11-22`r`n---`r`n`r`n"
        $body = "`r`n# 作業ログ`r`n[手入力](notes.md)"
        $old = "$header$start`r`n[← 2026-11-01](2026-11-01.md)`r`n$end`r`n$body"
        $updated = Update-MdhDailyNavigation -Content $old -TargetDate ([datetime]::new(2026, 11, 22)) `
            -PreviousDate '2026-11-20' -NextDate '2026-11-24'
        $updated | Should BeExactly "$header[← 2026-11-20](2026-11-20.md) | [→ 2026-11-24](2026-11-24.md)`r`n$body"
    }
}
