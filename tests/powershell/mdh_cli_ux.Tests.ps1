$repository = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

Describe 'MDH CLI presentation' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $scripts = Join-Path $root '40_scripts/pwsh_scripts'
        $settings = Join-Path $root '50_settings'
        $null = [IO.Directory]::CreateDirectory($scripts)
        $null = [IO.Directory]::CreateDirectory($settings)
        Copy-Item (Join-Path $repository '40_scripts/pwsh_scripts/mdh*.ps1') -Destination $scripts
        Copy-Item (Join-Path $repository '50_settings/config.template.json') -Destination (Join-Path $settings 'config.json')
        Copy-Item (Join-Path $repository '50_settings/templates') -Destination $settings -Recurse
        . (Join-Path $scripts 'mdh.ps1')
        Mock Open-IfExist {}
    }

    It 'documents every public parameter and exposes the requested help modes' {
        foreach ($name in 'mdstart', 'daily', 'mdtoday', 'todo', 'md-db', 'quicklinks', 'mdsearch', 'mdreverse', 'mdrun', 'mdversion', 'mdlist', 'mdhelp') {
            $help = Get-Help $name -Full
            $help.Synopsis | Should Not Match ('^' + [regex]::Escape($name) + ' \[')
            @($help.examples.example).Count | Should BeGreaterThan 0
            $documented = @($help.parameters.parameter | Where-Object { $_ -and $_.name -notin 'WhatIf', 'Confirm' } | ForEach-Object name | Sort-Object)
            $actual = @((Get-Command $name).ScriptBlock.Ast.Body.ParamBlock.Parameters |
                ForEach-Object { $_.Name.VariablePath.UserPath } | Sort-Object)
            ($documented -join ',') | Should Be ($actual -join ',')
        }
        (Get-Help daily).Synopsis | Should Match '日報'
        (Get-Help daily -Detailed | Out-String) | Should Match 'DateText'
        (Get-Help daily -Examples | Out-String) | Should Match '2026-10-31'
        (Get-Help mdstart -Examples | Out-String) | Should Match 'NoOpen'
        (Get-Help todo -Detailed | Out-String) | Should Match '完了タスク'
    }

    It 'reports the actual daily save decision and keeps the success stream empty' {
        $script:MDH_CONFIG.daily.update_schedule = $false
        $first = @(daily '2026-11-22' 3>&1 4>&1 6>&1)
        ($first -join ' ') | Should Match '新規作成'
        ($first -join ' ') | Should Match '2026-11-22.md'
        ($first -join ' ') | Should Not Match '保存先を確認'
        $path = Get-MdhDailyPath -DateText '2026-11-22'
        [IO.File]::AppendAllText($path, "`n手入力本文")
        $script:MDH_CONFIG.daily.update_schedule = $true
        Mock Get-MdhDailyAppointments {
            [pscustomobject]@{ Status = 'Available'; Appointments = @('- 09:00 確認') }
        }
        $second = @(daily '2026-11-22' -Verbose 3>&1 4>&1 6>&1)
        ($second -join ' ') | Should Match '\| 更新 \|'
        ($second -join ' ') | Should Match '保存先を確認'
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $third = @(daily '2026-11-22' 3>&1 4>&1 6>&1)
        ($third -join ' ') | Should Match '対象ファイルに変更なし'
        @($third | Where-Object { $_ -isnot [Management.Automation.InformationRecord] }).Count | Should Be 0
        (Get-FileHash -LiteralPath $path).Hash | Should Be $hash
        [IO.File]::ReadAllText($path) | Should Match '手入力本文'
    }

    It 'separates a partial DB summary from its response and keeps the exit contract' {
        Mock Invoke-MdhDbCommand {
            [pscustomobject]@{
                operation = 'sync'; contract_version = 1; exit_code = 1
                result = [pscustomobject]@{ indexed = 2; unchanged = 1; failed = 1; missing = 0; deleted = 0 }
                diagnostics = @([pscustomobject]@{ code = 'FIXTURE'; message = '診断の内容' })
            }
        } -ParameterFilter { $Operation -eq 'sync' }
        $items = @(md-db -Sync -Verbose 3>&1 4>&1 6>&1)
        $responses = @($items | Where-Object { $_.PSObject.Properties['contract_version'] })
        $responses.Count | Should Be 1
        $responses[0].exit_code | Should Be 1
        $LASTEXITCODE | Should Be 1
        ($items -join ' ') | Should Match '部分成功または保留.*索引反映 2 件'
        ($items -join ' ') | Should Match 'FIXTURE 診断の内容'
        @(md-db -Sync -WhatIf).Count | Should Be 0
        $LASTEXITCODE | Should Be 1
    }

    It 'preserves md-db ErrorAction Stop and LASTEXITCODE' {
        Mock Invoke-MdhDbCommand {
            New-MdhDbFailure -Operation 'status' -Code 3 -DiagnosticCode 'FIXTURE' -Message 'Python環境エラー'
        }
        $failure = try { md-db -Status -ErrorAction Stop 6>$null | Out-Null; $null } catch { $_ }
        $failure.FullyQualifiedErrorId | Should Match '^MDH_DB_3'
        $LASTEXITCODE | Should Be 3
    }

    It 'reports TODO counts and Quick Links changes without writing objects to the pipeline' {
        Write-Utf8 -Path (Get-MdhTodoRoutinePath) -Content "## ルーティン`n- [ ] fixture routine"
        $todoPath = Get-MdhTodoPath
        Write-Utf8 -Path $todoPath -Content "## Tasks`n- [x] keep checked"
        $items = @(todo 3>&1 6>&1)
        ($items -join ' ') | Should Match '警告付き完了.*ルーティン追加 1 件.*チェック保持 1 件'
        @($items | Where-Object {
            $_ -isnot [Management.Automation.InformationRecord] -and $_ -isnot [Management.Automation.WarningRecord]
        }).Count | Should Be 0
        [IO.File]::ReadAllText($todoPath) | Should Match '\[x\] keep checked'
        $hash = (Get-FileHash -LiteralPath $todoPath).Hash
        (quicklinks 6>&1 | Out-String) | Should Match '変更なし'
        (Get-FileHash -LiteralPath $todoPath).Hash | Should Be $hash
    }
}
