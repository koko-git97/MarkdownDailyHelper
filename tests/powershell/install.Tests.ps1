$repository = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

Describe 'MDH installer' {
    BeforeEach {
        $root = Join-Path $TestDrive ("MDH 日本語 ' " + [guid]::NewGuid())
        $null = [IO.Directory]::CreateDirectory($root)
        Copy-Item -LiteralPath (Join-Path $repository 'install.ps1') -Destination $root
        foreach ($folder in '40_scripts', '50_settings') {
            $destination = Join-Path $root $folder
            $null = [IO.Directory]::CreateDirectory($destination)
            $contents = Get-ChildItem -LiteralPath (Join-Path $repository $folder) |
                Where-Object Name -ne 'config.json'
            Copy-Item -LiteralPath $contents.FullName -Destination $destination -Recurse
        }
        $installer = Join-Path $root 'install.ps1'
        $config = Join-Path $root '50_settings/config.json'
        $loader = Join-Path $root '40_scripts/pwsh_scripts/mdh.ps1'
        $profileFile = Join-Path $root 'profile.ps1'
        $hostFile = Join-Path $root 'host.ps1'
        $PROFILE = [pscustomobject]@{ CurrentUserAllHosts = $profileFile; CurrentUserCurrentHost = $hostFile }
        $registration = ". '" + $loader.Replace("'", "''") + "'"
        $template = Join-Path $root '50_settings/config.template.json'
    }

    function Get-InstallerSnapshot($Path) {
        Get-ChildItem -LiteralPath $Path -Force -Recurse | ForEach-Object {
            $hash = if (-not $_.PSIsContainer) { (Get-FileHash -LiteralPath $_.FullName).Hash }
            "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)|$hash"
        }
    }

    It 'INS-AC-01/02/08/11 installs, loads and repeats without writes' {
        & $installer
        Test-Path -LiteralPath $config | Should Be $true
        $original = Get-Item -LiteralPath $profileFile
        $hash = (Get-FileHash -LiteralPath $profileFile).Hash
        & $installer
        (Get-FileHash -LiteralPath $profileFile).Hash | Should Be $hash
        (Get-Item -LiteralPath $profileFile).LastWriteTimeUtc | Should Be $original.LastWriteTimeUtc
        . $profileFile
        (Get-Command daily, todo, quicklinks, mdstart, md-db, mdsearch, mdreverse, mdrun).Count | Should Be 8
        @(Get-ChildItem -LiteralPath (Join-Path $root '01_Daily') -Recurse).Count | Should Be 0
        Test-Path -LiteralPath (Join-Path $root '00_QuickNotes/00_TODO.md') | Should Be $false
    }

    It 'INS-AC-03 plans without changes' {
        $fixedTime = [datetime]::new(2024, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        Get-ChildItem -LiteralPath $root -Directory -Recurse | ForEach-Object {
            [IO.Directory]::SetLastWriteTimeUtc($_.FullName, $fixedTime)
        }
        $initialTree = @(Get-InstallerSnapshot $root)
        & $installer -WhatIf
        $finalTree = @(Get-InstallerSnapshot $root)
        $differences = @(Compare-Object $initialTree $finalTree)
        $differences | ForEach-Object { Write-Host $_.InputObject }
        $differences.Count | Should Be 0
        Test-Path -LiteralPath $config | Should Be $false
    }

    It 'INS-AC-04/07 preserves configuration and UTF-16 profile bytes with backup' {
        Copy-Item -LiteralPath $template -Destination $config
        $configFile = Get-Item -LiteralPath $config
        $configHash = (Get-FileHash -LiteralPath $config).Hash
        $null = [IO.Directory]::CreateDirectory((Join-Path $root '00_QuickNotes'))
        $todo = Join-Path $root '00_QuickNotes/00_TODO.md'
        [IO.File]::WriteAllText($todo, '手入力')
        $todoHash = (Get-FileHash -LiteralPath $todo).Hash
        [IO.File]::WriteAllText($profileFile, "# 設定`n", [Text.Encoding]::Unicode)
        $original = [IO.File]::ReadAllBytes($profileFile)
        & $installer
        (Get-FileHash -LiteralPath $config).Hash | Should Be $configHash
        (Get-Item -LiteralPath $config).LastWriteTimeUtc | Should Be $configFile.LastWriteTimeUtc
        (Get-FileHash -LiteralPath $todo).Hash | Should Be $todoHash
        $backup = Get-ChildItem -LiteralPath $root -Filter '*.bak'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($backup.FullName)) | Should Be ([Convert]::ToBase64String($original))
        $new = [IO.File]::ReadAllBytes($profileFile)
        [Convert]::ToBase64String($new, 0, $original.Length) | Should Be ([Convert]::ToBase64String($original))
        [Text.Encoding]::Unicode.GetString($new).Contains("`r") | Should Be $false
    }

    It 'INS-AC-05/06 respects a hand-written host profile registration' {
        [IO.File]::WriteAllText($hostFile, $registration)
        & $installer
        Test-Path -LiteralPath $profileFile | Should Be $false
        [IO.File]::ReadAllText($hostFile) | Should Be $registration
    }

    It 'INS-AC-05 stops for broken markers, foreign registrations and duplicates' {
        foreach ($text in @('# >>> MDH managed >>>', ". 'C:\other\mdh.ps1'", "$registration`n$registration", '. $unknown')) {
            [IO.File]::WriteAllText($profileFile, $text)
            $failure = try { & $installer; '' } catch { $_.Exception.Message }
            $failure | Should Match '要修正で停止|一部適用'
            [IO.File]::ReadAllText($profileFile) | Should Be $text
            Test-Path -LiteralPath $config | Should Be $false
        }
    }

    It 'stops before writes for invalid configuration and missing scripts' {
        [IO.File]::WriteAllText($config, '{broken')
        $failure = try { & $installer; '' } catch { $_.Exception.Message }
        $failure | Should Match '要修正で停止|一部適用'
        [IO.File]::ReadAllText($config) | Should Be '{broken'
        [IO.File]::Delete($loader)
        $failure = try { & $installer; '' } catch { $_.Exception.Message }
        $failure | Should Match '要修正で停止|一部適用'
        Test-Path -LiteralPath $profileFile | Should Be $false
    }

    It 'INS-AC-07/10 preserves a locked profile and resumes after the lock is released' {
        [IO.File]::WriteAllText($profileFile, '# existing')
        $lock = [IO.File]::Open($profileFile, 'Open', 'Read', 'Read')
        try {
            $failure = try { & $installer; '' } catch { $_.Exception.Message }
            $failure | Should Match '要修正で停止|一部適用'
            Test-Path -LiteralPath $config | Should Be $true
            [IO.File]::ReadAllText($profileFile) | Should Be '# existing'
        }
        finally { $lock.Dispose() }
        & $installer
        [IO.File]::ReadAllText($profileFile) | Should Match 'MDH managed'
    }

    It 'INS-AC-07 restores the original after a partial append fails' {
        [IO.File]::WriteAllText($profileFile, '# original')
        $originalHash = (Get-FileHash -LiteralPath $profileFile).Hash
        $originalScript = [IO.File]::ReadAllText($installer)
        $fault = '$stream.WriteByte(65); throw "simulated partial append failure"'
        $instrumented = $originalScript.Replace('$stream.Write($bytes, $length, $bytes.Length - $length)', $fault)
        $instrumented | Should Not Be $originalScript
        [IO.File]::WriteAllText($installer, $instrumented)
        $failure = try { & $installer; '' } catch { $_.Exception.Message }
        $failure | Should Match '一部適用.*復元'
        (Get-FileHash -LiteralPath $profileFile).Hash | Should Be $originalHash
        @(Get-ChildItem -LiteralPath $root -Filter '*.bak').Count | Should Be 1
        @(Get-ChildItem -LiteralPath $root -Filter '*.tmp').Count | Should Be 0
    }

    It 'INS-AC-07 detects a profile edit between plan and apply' {
        [IO.File]::WriteAllText($profileFile, '# original')
        $literal = "'" + $profileFile.Replace("'", "''") + "'"
        [IO.File]::AppendAllText($loader, "`n[IO.File]::WriteAllText($literal, '# concurrent edit')`n")
        $failure = try { & $installer; '' } catch { $_.Exception.Message }
        $failure | Should Match '一部適用.*診断後'
        [IO.File]::ReadAllText($profileFile) | Should Be '# concurrent edit'
        @(Get-ChildItem -LiteralPath $root -Filter '*.bak').Count | Should Be 0
    }

    It 'INS-AC-07 keeps an edit made immediately before the write lock' {
        [IO.File]::WriteAllText($profileFile, '# original')
        $source = [IO.File]::ReadAllText($installer)
        $point = '$stream = [IO.File]::Open($Path, ''Open'', ''ReadWrite'', ''None'')'
        $source.Contains($point) | Should Be $true
        $edit = '[IO.File]::WriteAllText($Path, "# external edit"); '
        [IO.File]::WriteAllText($installer, $source.Replace($point, $edit + $point))
        $failure = try { & $installer; '' } catch { $_.Exception.Message }
        [IO.File]::ReadAllText($profileFile) | Should Be '# external edit'
        $failure | Should Match '変更'
    }

    It 'blocks a profile and a data destination behind a parent junction' {
        $destination = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $nested = Join-Path $destination 'nested'
        $null = [IO.Directory]::CreateDirectory($nested)
        $junction = Join-Path $root 'redirect'
        $null = New-Item -ItemType Junction -Path $junction -Target $destination
        try {
            $outsideProfile = Join-Path $nested 'profile.ps1'
            [IO.File]::WriteAllText($outsideProfile, '# original')
            $hash = (Get-FileHash -LiteralPath $outsideProfile).Hash
            $PROFILE.CurrentUserAllHosts = Join-Path $junction 'nested/profile.ps1'
            $failure = try { & $installer; '' } catch { $_.Exception.Message }
            (Get-FileHash -LiteralPath $outsideProfile).Hash | Should Be $hash
            $failure | Should Match 'ReparsePoint'
            Test-Path -LiteralPath $config | Should Be $false

            $PROFILE.CurrentUserAllHosts = $profileFile
            $settings = Get-Content -LiteralPath $template -Raw | ConvertFrom-Json
            $settings.paths | Add-Member -NotePropertyName daily -NotePropertyValue 'redirect/nested/new-daily'
            $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config
            $failure = try { & $installer; '' } catch { $_.Exception.Message }
            Test-Path -LiteralPath (Join-Path $nested 'new-daily') | Should Be $false
            $failure | Should Match 'ReparsePoint'
        }
        finally { [IO.Directory]::Delete($junction) }
    }

    It 'INS-AC-05 defers registration when a wrapper may already load MDH' {
        $wrapper = Join-Path $root 'wrapper.ps1'
        [IO.File]::WriteAllText($wrapper, $registration)
        $source = ". '" + $wrapper.Replace("'", "''") + "'"
        [IO.File]::WriteAllText($profileFile, $source)
        $failure = try { & $installer; '' } catch { $_.Exception.Message }
        [IO.File]::ReadAllText($profileFile) | Should Be $source
        $failure | Should Match '別スクリプト'
    }

    It 'preserves the other name of a hard-linked profile' {
        [IO.File]::WriteAllText($profileFile, '# original')
        $otherFile = Join-Path $root 'other.md'
        $null = New-Item -ItemType HardLink -Path $otherFile -Target $profileFile
        $failure = try { & $installer; '' } catch { $_.Exception.Message }
        $failure | Should Match 'ハードリンク'
        [IO.File]::ReadAllText($otherFile) | Should Be '# original'
        Test-Path -LiteralPath $config | Should Be $false
    }

    It 'INS-AC-03 never invokes the external Python probe in WhatIf' {
        $dbScript = Join-Path $root '40_scripts/pwsh_scripts/mdh_db.ps1'
        $sentinel = Join-Path $root 'python-started'
        $literal = "'" + $sentinel.Replace("'", "''") + "'"
        Add-Content -LiteralPath $dbScript -Value (
            "function Invoke-MdhDbProcess { [IO.File]::WriteAllText($literal, 'started'); throw 'probe invoked' }")
        $settings = Get-Content -LiteralPath $template -Raw | ConvertFrom-Json
        $settings.db.python = 'fixture-python.exe'
        $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config
        & $installer -WhatIf
        Test-Path -LiteralPath $sentinel | Should Be $false
    }

    It 'INS-AC-09 continues with an unavailable explicitly configured Python' {
        $settings = Get-Content -LiteralPath $template -Raw | ConvertFrom-Json
        $settings.db.python = 'missing.exe'
        $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config
        $originalPath = $env:PATH
        try {
            $env:PATH = $PSHOME
            $warnings = & $installer 3>&1
        }
        finally { $env:PATH = $originalPath }
        ($warnings -join ' ') | Should Match 'code CLI'
        ($warnings -join ' ') | Should Match 'requirements.txt'
        Test-Path -LiteralPath $profileFile | Should Be $true
    }

    It 'INS-AC-09 reports missing pinned dependencies without blocking installation' {
        $settings = Get-Content -LiteralPath $template -Raw | ConvertFrom-Json
        $settings.db.python = 'fixture-python.exe'
        $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config
        $dbScript = Join-Path $root '40_scripts/pwsh_scripts/mdh_db.ps1'
        @'

function Invoke-MdhDbProcess {
    param($Python, $Operation, $Timeout, $Module)
    [pscustomobject]@{ exit_code = 3; diagnostics = @([pscustomobject]@{
        message = 'markdown-it-py==3.0.0 is required'
    }) }
}
'@ | Add-Content -LiteralPath $dbScript
        $warnings = & $installer 3>&1
        ($warnings -join ' ') | Should Match 'markdown-it-py==3.0.0'
        Test-Path -LiteralPath $profileFile | Should Be $true
    }
}
