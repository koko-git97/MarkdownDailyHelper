# 40_scripts/pwsh_scripts/mdh_init.ps1

function Read-MdhConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MDHRoot,

        [Parameter(Mandatory)]
        [string]$MDHConfig
    )

    $MDHRoot = [System.IO.Path]::GetFullPath($MDHRoot)
    $MDHConfig = [System.IO.Path]::GetFullPath($MDHConfig)

    if (-not (Test-Path -LiteralPath $MDHConfig -PathType Leaf)) {
        throw "設定ファイルが見つかりません: $MDHConfig"
    }

    try {
        $json = Get-Content -LiteralPath $MDHConfig -Raw -Encoding UTF8 -ErrorAction Stop
        try {
            $config = $json | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            if ($_.FullyQualifiedErrorId -notlike 'KeysWithDifferentCasingInJsonString,*') { throw }
            $configWithoutConcepts = $json | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($configWithoutConcepts -isnot [System.Collections.IDictionary] -or
                -not $configWithoutConcepts.Contains('concepts')) { throw }
            # The aggregate CLI reads the original Concept map, including case-only names.
            $configWithoutConcepts.Remove('concepts')
            $config = $configWithoutConcepts | ConvertTo-Json -Depth 100 | ConvertFrom-Json -ErrorAction Stop
        }
    }
    catch {
        throw "config.json の読み込みに失敗しました: $($_.Exception.Message)"
    }

    if ($config -isnot [pscustomobject] -or $config.paths -isnot [pscustomobject]) {
        throw "config.json の paths は JSON オブジェクトで指定してください。"
    }

    $configuredRoot = if ($config.paths -and $config.paths.MDH_root) {
        [System.IO.Path]::GetFullPath([string]$config.paths.MDH_root)
    }
    else {
        $MDHRoot
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$config.paths.MDH_root)) {
        if ($configuredRoot -ne $MDHRoot) {
            throw "MDHRoot と config.paths.MDH_root が一致しません。"
        }
    }

    $pathValues = @{
        "MDH_root" = $MDHRoot
    }

    $resolvedNames = @("daily", "quicknotes", "aggregate")
    foreach ($name in $resolvedNames) {
        $value = [string]($config.paths.$name)

        if ([string]::IsNullOrWhiteSpace($value)) {
            switch ($name) {
                "daily" { $value = "01_Daily" }
                "quicknotes" { $value = "00_QuickNotes" }
                "aggregate" { $value = "10_Aggregate" }
            }
        }

        $resolved = [regex]::Replace(
            $value,
            '\{([^{}]+)\}',
            {
                param($match)

                $key = $match.Groups[1].Value

                if (-not $pathValues.ContainsKey($key)) {
                    throw "未定義のパス参照です: {$key}"
                }

                return $pathValues[$key]
            }
        )

        if (-not [System.IO.Path]::IsPathRooted($resolved)) {
            $resolved = Join-Path $MDHRoot $resolved
        }

        $pathValues[$name] = [System.IO.Path]::GetFullPath($resolved)
    }

    $config.paths | Add-Member -NotePropertyName MDH_root -NotePropertyValue $MDHRoot -Force
    foreach ($name in $resolvedNames) {
        $config.paths | Add-Member `
            -MemberType NoteProperty `
            -Name $name `
            -Value $pathValues[$name] `
            -Force
    }

    return $config
}

function Initialize-MDH {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MDHRoot,
        [Parameter(Mandatory)][string]$MDHConfig,
        [switch]$RequireExisting
    )

    $config = Read-MdhConfiguration -MDHRoot $MDHRoot -MDHConfig $MDHConfig
    foreach ($dir in @($config.paths.daily, $config.paths.quicknotes, $config.paths.aggregate)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            if ($RequireExisting) { throw "保存先が存在しません: $dir" }
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    $script:MDH_CONFIG = $config
    $script:MDHRoot = $config.paths.MDH_root

}
