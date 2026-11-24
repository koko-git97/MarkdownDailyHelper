function Get-MdhQuickLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$TargetPath,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $relativePath = [System.IO.Path]::GetRelativePath(
        (Split-Path -Parent $SourcePath),
        $TargetPath
    ).Replace('\', '/')

    return "  - [$Label]($relativePath)"
}

function Get-MdhQuickLinkContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TodoPath,

        [Parameter(Mandatory)]
        [string]$DateText
    )

    $targetDate = ConvertTo-MdhDailyDate -DateText $DateText
    $year = $targetDate.ToString('yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
    $todayPath = Get-MdhDailyPath -DateText $DateText
    $previousDate = Get-MdhLastDailyDate -BeforeDate $DateText
    if (-not $previousDate) {
        $previousDate = $targetDate.AddDays(-1).ToString(
            'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }

    $links = [System.Collections.Generic.List[string]]::new()
    $links.Add('### 📎 今日のページ')
    $links.Add((Get-MdhQuickLink -SourcePath $TodoPath -TargetPath $todayPath -Label '今日のログ'))
    $links.Add((Get-MdhQuickLink `
            -SourcePath $TodoPath `
            -TargetPath (Get-MdhDailyPath -DateText $previousDate) `
            -Label '前日のログ'))

    $archivePath = Join-Path $script:MDHRoot "$year\todo_archive\todo_arc.md"
    $latestDaily = Get-MdhLatestTodoDaily -BeforeOrOnDate $DateText
    if ($latestDaily -or (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        $links.Add('')
        $links.Add('### 🗂️ 管理')
        if ($latestDaily) {
            $links.Add((Get-MdhQuickLink `
                    -SourcePath $TodoPath `
                    -TargetPath $latestDaily.Path `
                    -Label '完了タスクの記録'))
        }
    }
    if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
        $links.Add((Get-MdhQuickLink -SourcePath $TodoPath -TargetPath $archivePath -Label 'アーカイブ'))
    }

    $taskLinks = [System.Collections.Generic.List[string]]::new()
    if ($script:MDH_CONFIG.tasks) {
        foreach ($property in $script:MDH_CONFIG.tasks.PSObject.Properties) {
            $taskName = $property.Name
            $taskConfig = $property.Value
            $relativeDirectory = if (-not [string]::IsNullOrWhiteSpace([string]$taskConfig.rel_dir)) {
                [string]$taskConfig.rel_dir
            }
            else {
                [string]$taskName
            }

            $indexFile = switch ([string]$taskConfig.mode) {
                'aggregate' { 'index.md' }
                'tag_index' { 'tag.md' }
                'monthly_archive' { 'index.md' }
                default { $null }
            }
            if (-not $indexFile) {
                continue
            }

            $taskPath = [System.IO.Path]::GetFullPath(
                (Join-Path $script:MDHRoot "$year\$relativeDirectory\$indexFile")
            )
            $rootPrefix = [System.IO.Path]::GetFullPath($script:MDHRoot).TrimEnd('\') + '\'
            if (-not $taskPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Warning "Quick Links のタスクパスが MDH ルート外のためスキップします: $taskName"
                continue
            }

            if (Test-Path -LiteralPath $taskPath -PathType Leaf) {
                $taskLinks.Add((Get-MdhQuickLink `
                        -SourcePath $TodoPath `
                        -TargetPath $taskPath `
                        -Label ([string]$taskName)))
            }
        }
    }

    if ($taskLinks.Count -gt 0) {
        $links.Add('')
        $links.Add('### 📚 主要ページ')
        foreach ($taskLink in $taskLinks) {
            $links.Add($taskLink)
        }
    }

    return $links.ToArray()
}

function Update-MdhQuickLinks {
    [CmdletBinding()]
    param(
        [string]$Path = (Get-MdhTodoPath),

        [string]$DateText = (Get-Date -Format 'yyyy-MM-dd'),

        [ref]$Result
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Quick Links の更新対象がありません。先に todo を実行してください: $Path"
    }

    $file = Read-MdhTextFile -Path $Path
    $document = ConvertTo-MdhTodoLines -Content $file.Content
    $lines = $document.Lines

    $startMarker = '<!-- MDH:QUICKLINKS:START -->'
    $endMarker = '<!-- MDH:QUICKLINKS:END -->'
    $startIndexes = @()
    $endIndexes = @()
    $quickLinkHeaders = @()
    $openBlock = $false
    $syntax = [regex]::Split((Get-MdhMarkdownSyntax -Content $file.Content -HasOpenBlock ([ref]$openBlock)), '\r\n|\n|\r')
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($syntax[$index] -ceq $startMarker) {
            $startIndexes += $index
        }
        if ($syntax[$index] -ceq $endMarker) {
            $endIndexes += $index
        }
        if ($syntax[$index] -match '^ {0,3}##[ \t]+🔗[ \t]*Quick Links[ \t]*$') {
            $quickLinkHeaders += $index
        }
    }
    if ($openBlock -or $quickLinkHeaders.Count -gt 1) {
        Write-Warning 'Quick Links の見出しやMarkdown境界が曖昧なため更新しません。'
        return
    }
    $sectionEnd = $lines.Count
    if ($quickLinkHeaders.Count -eq 1) {
        for ($index = $quickLinkHeaders[0] + 1; $index -lt $lines.Count; $index++) {
            if ($syntax[$index] -match '^ {0,3}#{1,2}[ \t]+') {
                $sectionEnd = $index
                break
            }
        }
    }

    if ($startIndexes.Count -gt 0 -or $endIndexes.Count -gt 0) {
        if ($startIndexes.Count -ne 1 -or $endIndexes.Count -ne 1 -or
            $quickLinkHeaders.Count -ne 1 -or $startIndexes[0] -le $quickLinkHeaders[0] -or
            $startIndexes[0] -ge $endIndexes[0] -or $endIndexes[0] -ge $sectionEnd) {
            Write-Warning 'Quick Links の管理マーカーは同じ一意な見出しの配下に必要です。更新しません。'
            return
        }
        for ($index = $startIndexes[0] + 1; $index -lt $endIndexes[0]; $index++) {
            if ($lines[$index] -cnotmatch '^(?:[ \t]*|### (?:📎 今日のページ|🗂️ 管理|📚 主要ページ)|  - \[[^\r\n]+\]\([^\r\n]+\))$' -or
                $lines[$index] -cne $syntax[$index]) {
                Write-Warning 'Quick Links の管理範囲に既知の自動生成形式以外の行があるため更新しません。'
                return
            }
        }

        $generatedLinks = @(Get-MdhQuickLinkContent -TodoPath $Path -DateText $DateText)
        $start = $startIndexes[0] + 1
        $updatedContent = Edit-MdhTodoLines -Content $file.Content -Document $document -Start $start `
            -Count ($endIndexes[0] - $start) -Lines $generatedLinks
    }
    else {
        if ($file.Content -match '(?i)MDH:QUICKLINKS:') {
            Write-Warning 'Quick Links の管理マーカーを安全に識別できないため更新しません。'
            return
        }

        $generatedLinks = @(Get-MdhQuickLinkContent -TodoPath $Path -DateText $DateText)
        $block = @($startMarker) + $generatedLinks + @($endMarker)
        if ($quickLinkHeaders.Count -eq 0) {
            if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
                $block = @('','## 🔗 Quick Links') + $block
            }
            else {
                $block = @('## 🔗 Quick Links') + $block
            }
            $insertIndex = $lines.Count
        }
        else {
            $headerIndex = $quickLinkHeaders[0]
            $insertIndex = $sectionEnd
            while ($insertIndex -gt $headerIndex + 1 -and
                [string]::IsNullOrWhiteSpace($lines[$insertIndex - 1])) {
                $insertIndex--
            }
            if ($insertIndex -gt $headerIndex + 1) {
                $block = @('') + $block
            }
        }
        $updatedContent = Edit-MdhTodoLines -Content $file.Content -Document $document -Start $insertIndex -Lines $block
    }

    $saveResult = '変更なし'
    if ($updatedContent -cne $file.Content) {
        Write-MdhTextFile `
            -Path $Path `
            -Content $updatedContent `
            -Utf8Bom:$file.HasUtf8Bom `
            -ExpectedHash $file.Hash
        $saveResult = '更新'
    }
    if ($Result) { $Result.Value = $saveResult }
    Write-Verbose "Quick Links | $saveResult | $Path"
}

<#
.SYNOPSIS
TODOの Quick Links を更新して開きます。
.DESCRIPTION
識別できる Quick Links 管理領域を更新します。
.PARAMETER DateText
リンク生成の基準日を yyyy-MM-dd で指定します。既定は今日です。
.EXAMPLE
quicklinks -DateText '2026-10-31'
.NOTES
管理範囲が曖昧なときは警告します。
#>
function quicklinks {
    [CmdletBinding()]
    param(
        [string]$DateText = (Get-Date -Format 'yyyy-MM-dd')
    )

    $todoPath = Get-MdhTodoPath
    $saveResult = '更新を保留'
    Update-MdhQuickLinks -Path $todoPath -DateText $DateText -Result ([ref]$saveResult) -WarningVariable linkWarnings
    $status = if ($linkWarnings) { "警告付き完了（$saveResult）" } else { $saveResult }
    Write-Host "quicklinks | $status | $todoPath"
    Open-IfExist -Path $todoPath
}
