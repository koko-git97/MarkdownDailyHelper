Describe 'mdreverse and mdrun from the production loader' {
    It 'uses Daily Markdown directly, persists registration, protects exports and reports aggregate failures' -Skip:(-not $env:MDH_TEST_PYTHON_EXECUTABLE) {
        $root = Join-Path $TestDrive 'MDH aggregate'
        $scripts = Join-Path $root '40_scripts'
        $settings = Join-Path $root '50_settings'
        $package = Join-Path $scripts 'py_scripts/mdh_db'
        $null = New-Item -ItemType Directory -Path $settings, $package -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../40_scripts/pwsh_scripts') -Destination $scripts -Recurse
        Copy-Item (Join-Path $PSScriptRoot '../../40_scripts/py_scripts/mdh_db/*.*') -Destination $package
        $configuration = Join-Path $settings 'config.json'
        @{
            paths = @{ MDH_root = '' }
            db = @{ python = $env:MDH_TEST_PYTHON_EXECUTABLE; store_dir = 'unused SQLite' }
            concepts = @{ '既存' = @{ keywords = @('sample'); category = '開発' } }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configuration -Encoding utf8
        . (Join-Path $scripts 'pwsh_scripts/mdh.ps1')
        $month = Join-Path $root '01_Daily/2026/2026-11'
        $null = New-Item -ItemType Directory -Path $month -Force
        $daily = Join-Path $month '2026-11-23.md'
        $source = "# ✅ やったこと`n`n## [Meeting]sample`n`n本文`n"
        [IO.File]::WriteAllText($daily, $source)
        $aggregate = Join-Path $root '10_Aggregate'

        mdreverse sample -Register -Type Meeting -ErrorAction SilentlyContinue
        $LASTEXITCODE | Should Be 2
        $preview = mdreverse sample -Type ' meeting '
        $LASTEXITCODE | Should Be 0
        $preview | Should Match '## Meeting'
        $preview | Should Match '2026-11-23｜sample'
        @(Get-ChildItem -LiteralPath $aggregate -File -Recurse).Count | Should Be 0

        mdreverse sample
        $LASTEXITCODE | Should Be 0
        $standard = Join-Path $aggregate 'sample.md'
        (Test-Path -LiteralPath $standard -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $aggregate 'index.md')) | Should Be $false

        Push-Location -LiteralPath $root
        try {
            mdreverse sample -Type Meeting -OutputPath './report.md'
            $LASTEXITCODE | Should Be 0
            $export = Join-Path $root 'report.md'
            [IO.File]::ReadAllText($export) | Should Match '"kind":"export"'
            mdreverse sample -Type Review -OutputPath './report.md'
            $LASTEXITCODE | Should Be 0
            [IO.File]::ReadAllText($export) | Should Match '"type":"Meeting"'
            mdreverse sample -OutputPath './report.md' -ErrorAction SilentlyContinue
            $LASTEXITCODE | Should Be 4
        }
        finally { Pop-Location }

        mdreverse sample -Register
        $LASTEXITCODE | Should Be 0
        $savedConfig = [IO.File]::ReadAllText($configuration) | ConvertFrom-Json
        $savedConfig.concepts.sample.keywords.Count | Should Be 0
        $savedConfig.concepts.'既存'.category | Should Be '開発'
        mdrun
        $LASTEXITCODE | Should Be 0
        $index = Join-Path $aggregate 'index.md'
        [IO.File]::ReadAllText($index) | Should Match '\[既存\]\('
        if ($IsWindows) {
            $physical = Join-Path $root '物理 集約'
            $exportDirectory = Join-Path $root '物理 export'
            $exportAlias = Join-Path $root '論理 export'
            [IO.Directory]::Move($aggregate, $physical)
            try {
                $null = New-Item -ItemType Junction -Path $aggregate -Target $physical
                $null = New-Item -ItemType Directory -Path $exportDirectory
                $null = New-Item -ItemType Junction -Path $exportAlias -Target $exportDirectory
                mdreverse sample
                $LASTEXITCODE | Should Be 0
                mdrun
                $LASTEXITCODE | Should Be 0
                [IO.File]::ReadAllText((Join-Path $physical 'index.md')) | Should Match '\[sample\]\(sample\.md\)'
                mdreverse sample -OutputPath (Join-Path $exportAlias '報告 書.md')
                $LASTEXITCODE | Should Be 0
                [IO.File]::ReadAllText((Join-Path $exportDirectory '報告 書.md')) | Should Match '"kind":"export"'

                [IO.Directory]::Delete($aggregate)
                $guidJunction = @'
import os, subprocess, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from test_aggregate import volume_alias
subprocess.run(["cmd.exe", "/d", "/c", "mklink", "/J", sys.argv[2], str(volume_alias(Path(sys.argv[3])))],
               check=True, capture_output=True)
assert "Volume{" in os.readlink(sys.argv[2])
'@
                & $env:MDH_TEST_PYTHON_EXECUTABLE -B -c $guidJunction (Join-Path $PSScriptRoot '../python/mdh_db') $aggregate $physical
                $LASTEXITCODE | Should Be 0
                mdreverse sample
                $LASTEXITCODE | Should Be 0
                mdrun
                $LASTEXITCODE | Should Be 0
                [IO.File]::ReadAllText((Join-Path $physical 'index.md')) | Should Match '\[sample\]\(sample\.md\)'
            }
            finally {
                if ([IO.Directory]::Exists($exportAlias)) { [IO.Directory]::Delete($exportAlias) }
                if ([IO.Directory]::Exists($aggregate)) { [IO.Directory]::Delete($aggregate) }
                [IO.Directory]::Move($physical, $aggregate)
            }
        }
        $indexHash = (Get-FileHash -LiteralPath $index).Hash
        [IO.File]::WriteAllText($standard, 'personal text')
        mdrun -ErrorAction SilentlyContinue
        $LASTEXITCODE | Should Be 1
        (Get-FileHash -LiteralPath $index).Hash | Should Be $indexHash
        [IO.File]::ReadAllText($standard) | Should Be 'personal text'

        $caseConfig = [IO.File]::ReadAllText($configuration) | ConvertFrom-Json -AsHashtable
        $caseConfig.concepts['SAMPLE'] = @{}
        $caseConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configuration -Encoding utf8
        . (Join-Path $scripts 'pwsh_scripts/mdh.ps1')
        mdrun -ErrorAction SilentlyContinue -ErrorVariable collision
        $LASTEXITCODE | Should Be 1
        ($collision -join ' ') | Should Match 'collides'
        (Get-FileHash -LiteralPath $index).Hash | Should Be $indexHash

        [IO.File]::WriteAllText((Join-Path $month '2026-11-24.md'), '# Invalid Daily')
        mdreverse '追加入力' -Register -ErrorAction SilentlyContinue
        $LASTEXITCODE | Should Be 4
        ([IO.File]::ReadAllText($configuration) | ConvertFrom-Json -AsHashtable).concepts.'追加入力'.keywords.Count | Should Be 0
        (Get-FileHash -LiteralPath $index).Hash | Should Be $indexHash
        [IO.File]::ReadAllText($daily) | Should BeExactly $source
        (Test-Path -LiteralPath (Join-Path $root 'unused SQLite')) | Should Be $false
    }
}
