function Invoke-MdhAggregate {
    [CmdletBinding()]
    param([string]$Operation, [string[]]$Arguments = @(), [string]$WorkingDirectory)

    $module = 'mdh_db.aggregate_cli'
    try {
        $root = $script:MDHRoot
        if (-not $root -or -not $script:MDH_CONFIG.paths.daily -or -not $script:MDH_CONFIG.paths.aggregate) {
            throw 'MDH を読み込んでから集約コマンドを実行してください。'
        }
        $configuredPython = $script:MDH_CONFIG.db.python
        if ($null -ne $configuredPython -and $configuredPython -isnot [string]) {
            throw 'config.db.python は文字列で指定してください。'
        }
        $settings = @{
            Root = $root
            Python = if ($configuredPython) { Get-MdhDbAbsolutePath -Root $root -Value $configuredPython }
        }
    }
    catch {
        $global:LASTEXITCODE = 2
        Write-Error $_
        return
    }

    try {
        $python = Resolve-MdhDbPython -Settings $settings -Module $module
    }
    catch {
        $global:LASTEXITCODE = 3
        Write-Error $_
        return
    }
    try {
        $configuration = Join-Path $root '50_settings/config.json'
        $argumentsToSend = @(
            "--config=$configuration"
            "--daily-root=$($script:MDH_CONFIG.paths.daily)"
            "--aggregate-root=$($script:MDH_CONFIG.paths.aggregate)"
            "--cwd=$WorkingDirectory"
        ) + $Arguments
        $result = Invoke-MdhDbProcess -Python $python -Module $module -Operation $Operation -Arguments $argumentsToSend
    }
    catch {
        $global:LASTEXITCODE = 4
        Write-Error $_
        return
    }

    $global:LASTEXITCODE = [int]$result.exit_code
    if ($result.result.registered) { Write-Host 'Concept を登録しました。' }
    foreach ($entry in $result.result.concepts) {
        if (-not $entry.topics) { Write-Host "$($entry.name) は該当 Topic がありません。" }
        elseif ($entry.path) { Write-Host "$($entry.name) は $($entry.topics) 件です。$($entry.path)" }
    }
    foreach ($warning in $result.result.warnings) { Write-Warning $warning }
    if ($result.result.markdown) { Write-Output $result.result.markdown }
    if ($result.exit_code -ne 0) {
        $summary = if ($result.exit_code -eq 1) { '集約は一部失敗しました。' } else { '集約に失敗しました。' }
        Write-Error "$summary $($result.diagnostics.message -join ' / ')"
    }
    elseif ($Operation -eq 'run') {
        Write-Host "集約が完了しました。Concept $($result.result.concepts.Count) 件。"
    }
}

<#
.SYNOPSIS
Conceptで日報のTopicを集約します。
.DESCRIPTION
Daily Markdownを直接読み、検索用DBを経由せずに該当するTopicを集約します。
.PARAMETER Concept
対象のConcept名を指定します。
.PARAMETER Type
出力対象のTypeを指定します。既定は全Typeです。
.PARAMETER OutputPath
export先を指定します。相対パスは現在の作業ディレクトリ基準です。
.PARAMETER Register
Conceptを登録します。Type または OutputPath と併用できません。
.EXAMPLE
mdreverse '図書整理'
.NOTES
Topic が0件のときは既存の集約・exportを保持します。
#>
function mdreverse {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Concept,
        [ValidateNotNullOrEmpty()]
        [string]$Type,
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath,
        [switch]$Register
    )

    $workingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
    $arguments = @("--concept=$Concept")
    if ($Register -and ($PSBoundParameters.ContainsKey('Type') -or $PSBoundParameters.ContainsKey('OutputPath'))) {
        $global:LASTEXITCODE = 2
        Write-Error '-Register は -Type または -OutputPath と併用できません。'
        return
    }
    if ($Register) { $arguments += '--register' }
    if ($PSBoundParameters.ContainsKey('Type')) { $arguments += "--type=$Type" }
    if ($PSBoundParameters.ContainsKey('OutputPath')) {
        try {
            $arguments += "--output=$(Get-MdhDbAbsolutePath -Value $OutputPath -Root $workingDirectory)"
        }
        catch {
            $global:LASTEXITCODE = 2
            Write-Error $_
            return
        }
    }
    Invoke-MdhAggregate -Operation reverse -Arguments $arguments -WorkingDirectory $workingDirectory
}

<#
.SYNOPSIS
登録済みのConceptを集約します。
.DESCRIPTION
日報から登録済みConceptの集約を生成し、全件成功したときにindexを更新します。
.EXAMPLE
mdrun
.NOTES
集約には製品用のPython環境が必要です。
#>
function mdrun {
    [CmdletBinding()]
    param()

    Invoke-MdhAggregate -Operation run -WorkingDirectory (Get-Location -PSProvider FileSystem).ProviderPath
}
