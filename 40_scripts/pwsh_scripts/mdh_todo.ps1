# todo.md の設定パスを解決し、絶対パスを取得する。
function Get-MdhTodoPath {
    [CmdletBinding()]
    param()

    if (-not $script:MDH_CONFIG -or -not $script:MDH_CONFIG.todo) {
        throw 'config.todo が初期化されていません。MDH の初期化を実行してください。'
    }

    $mdhRoot = if (-not [string]::IsNullOrWhiteSpace([string]$script:MDHRoot)) {
        [System.IO.Path]::GetFullPath([string]$script:MDHRoot)
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$script:MDH_CONFIG.paths.MDH_root)) {
        [System.IO.Path]::GetFullPath([string]$script:MDH_CONFIG.paths.MDH_root)
    }
    else {
        throw 'MDH のルートパスが初期化されていません。'
    }

    $todoFile = [string]$script:MDH_CONFIG.todo.file
    if ([string]::IsNullOrWhiteSpace($todoFile)) {
        $todoFile = '{quicknotes}\00_TODO.md'
    }

    $pathValues = @{
        MDH_root = $mdhRoot
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:MDH_CONFIG.paths.quicknotes)) {
        $pathValues.quicknotes = [string]$script:MDH_CONFIG.paths.quicknotes
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:MDH_CONFIG.paths.daily)) {
        $pathValues.daily = [string]$script:MDH_CONFIG.paths.daily
    }

    $resolved = Expand-MdhPathPlaceholders -Value $todoFile -PathValues $pathValues -Setting 'todo.file'

    if (-not [System.IO.Path]::IsPathRooted($resolved)) {
        $resolved = Join-Path $mdhRoot $resolved
    }

    return [System.IO.Path]::GetFullPath($resolved)
}

# ルーティンファイルの設定パスを絶対パスに解決する。
function Get-MdhTodoRoutinePath {
    [CmdletBinding()]
    param()

    $mdhRoot = if (-not [string]::IsNullOrWhiteSpace([string]$script:MDHRoot)) {
        [System.IO.Path]::GetFullPath([string]$script:MDHRoot)
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$script:MDH_CONFIG.paths.MDH_root)) {
        [System.IO.Path]::GetFullPath([string]$script:MDH_CONFIG.paths.MDH_root)
    }
    else {
        throw 'MDH のルートパスが初期化されていません。'
    }

    $routineFile = [string]$script:MDH_CONFIG.todo.routine_file
    if ([string]::IsNullOrWhiteSpace($routineFile)) {
        $routineFile = '50_settings\templates\TodoRoutine.md'
    }

    if (-not [System.IO.Path]::IsPathRooted($routineFile)) {
        $routineFile = Join-Path $mdhRoot $routineFile
    }

    return [System.IO.Path]::GetFullPath($routineFile)
}

# Markdown本文を行単位に分割し、改行コードとともに返す。
function ConvertTo-MdhTodoLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $endings = [regex]::Matches($Content, '\r\n|\n|\r')
    return [pscustomobject]@{
        Lines   = [string[]][regex]::Split($Content, '\r\n|\n|\r')
        Offsets = @(0; foreach ($ending in $endings) { $ending.Index + $ending.Length }; $Content.Length)
        Endings = $endings
    }
}

# 元の行境界で部分置換し、新規行には直近の既存改行を使う。
function Edit-MdhTodoLines {
    param([string]$Content, $Document, [int]$Start, [int]$Count = 0, [string[]]$Lines = @())

    $from = $Document.Offsets[$Start]
    $to = $Document.Offsets[$Start + $Count]
    $replacement = ''
    if ($Lines.Count) {
        $endingIndex = [Math]::Min($Start - 1, $Document.Endings.Count - 1)
        $newline = if ($Document.Endings.Count) { $Document.Endings[[Math]::Max(0, $endingIndex)].Value } else { [Environment]::NewLine }
        $replacement = $Lines -join $newline
        if ($Start + $Count -lt $Document.Lines.Count) {
            $replacement += $newline
        }
        elseif ($Start -eq $Document.Lines.Count -and $Content.Length) {
            $replacement = $newline + $replacement
        }
    }
    return $Content.Remove($from, $to - $from).Insert($from, $replacement)
}

# Markdownのチェックボックス行を解析し、完了状態とタスク内容を取得する。
function ConvertFrom-MdhTodoCheckbox {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Line
    )

    if ($Line -notmatch '^(?<indent>[ \t]*)(?:[-*+]|\d+[.)])[ \t]+\[(?<state>[ xX])\][ \t]+(?<text>.*?)[ \t]*$') {
        return $null
    }

    $taskText = [string]$Matches.text
    if ([string]::IsNullOrWhiteSpace($taskText)) {
        return $null
    }

    return [pscustomobject]@{
        IsComplete = $Matches.state -match '[xX]'
        Text       = $taskText.Trim()
    }
}

# ルーティン定義ファイルからタスク一覧を取得する。
function Get-MdhTodoRoutineTasks {
    [CmdletBinding()]
    param()

    $legacyRoutines = $script:MDH_CONFIG.todo.PSObject.Properties['routines']
    if ($legacyRoutines -and @($legacyRoutines.Value).Count -gt 0) {
        Write-Warning 'config.todo.routines は使われません。項目を routine_file のMarkdownファイルへ移してください。'
    }

    $routinePath = Get-MdhTodoRoutinePath
    if (-not (Test-Path -LiteralPath $routinePath -PathType Leaf)) {
        Write-Warning "ルーティンファイルがありません。ルーティンの反映をスキップします: $routinePath"
        return @()
    }

    $routineContent = (Read-MdhTextFile -Path $routinePath).Content
    $routineLines = ConvertTo-MdhTodoLines -Content $routineContent
    $tasks = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $routineLines.Lines) {
        $checkbox = ConvertFrom-MdhTodoCheckbox -Line $line
        if ($checkbox) {
            $tasks.Add($checkbox.Text)
        }
    }

    return $tasks.ToArray()
}

# 指定日以前に存在する最新の日報を取得する。
function Get-MdhLatestTodoDaily {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BeforeOrOnDate
    )

    $latestDate = @(Get-MdhExistingDailyDates |
        Where-Object { $_ -le $BeforeOrOnDate } |
        Sort-Object -Descending |
        Select-Object -First 1)

    if ($latestDate.Count -eq 0) {
        return $null
    }

    $dateText = [string]$latestDate[0]
    return [pscustomobject]@{
        DateText = $dateText
        Path     = Get-MdhDailyPath -DateText $dateText
    }
}

function Get-MdhDailyTodoRegion {
    param([string]$Syntax)

    $automationHeadings = [regex]::Matches($Syntax, '(?m)^[ ]{0,3}#[ \t]+🤖[ \t]+自動入力(?:[ \t]+#+)?[ \t]*\r?$')
    if ($automationHeadings.Count -ne 1) {
        return
    }

    $automation = $automationHeadings[0]
    $nextH1 = [regex]::new('(?m)^[ ]{0,3}#[ \t]+').Match($Syntax, $automation.Index + $automation.Length)
    $automationEnd = if ($nextH1.Success) { $nextH1.Index } else { $Syntax.Length }
    $children = $Syntax.Substring($automation.Index, $automationEnd - $automation.Index)
    $doneHeadings = [regex]::Matches($children, '(?m)^[ ]{0,3}##[ \t]+done(?:[ \t]+#+)?[ \t]*(?<newline>\r?\n|\z)')
    if ($doneHeadings.Count -ne 1) {
        return
    }

    $done = $doneHeadings[0]
    $start = $automation.Index + $done.Index + $done.Length
    $nextH2 = [regex]::new('(?m)^[ ]{0,3}##[ \t]+').Match($Syntax, $start)
    $end = if ($nextH2.Success -and $nextH2.Index -lt $automationEnd) {
        $nextH2.Index
    }
    else {
        $automationEnd
    }

    return [pscustomobject]@{
        Start = $start
        End = $end
        NewLine = $done.Groups['newline'].Value
        AutomationStart = $automation.Index
        AutomationEnd = $automationEnd
    }
}

function Get-MdhLegacyTodoHistory {
    param([string]$Syntax, $Region)

    $h1Pattern = [regex]::new('(?m)^[ ]{0,3}#[ \t]+')
    foreach ($heading in [regex]::Matches($Syntax, '(?m)^[ ]{0,3}#{1,2}[ \t]+✅[ \t]*やったこと(?:[ \t]+#+)?[ \t]*\r?$')) {
        if ($Region -and $heading.Index -ge $Region.AutomationStart -and
            $heading.Index -lt $Region.AutomationEnd) {
            continue
        }
        # Include sibling H2 headings because legacy TODO could insert an H2 after an H2 work heading.
        $start = $heading.Index + $heading.Length
        $next = $h1Pattern.Match($Syntax, $start)
        $end = if ($next.Success) { $next.Index } else { $Syntax.Length }
        $Syntax.Substring($start, $end - $start)
    }
}

# 日報に記録済みのルーティンタスクを取得する。
function Get-MdhRecordedRoutineTasks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DailyContent,

        [Parameter(Mandatory)]
        [string]$DateText
    )

    $recorded = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $syntax = Get-MdhMarkdownSyntax -Content $DailyContent
    $region = Get-MdhDailyTodoRegion -Syntax $syntax
    $history = @(Get-MdhLegacyTodoHistory -Syntax $syntax -Region $region)
    if ($region) {
        $history += $syntax.Substring($region.Start, $region.End - $region.Start)
    }
    foreach ($line in [regex]::Split(($history -join "`n"), '\r\n|\n|\r')) {
        if ($line -match '^[ \t]*[-*+][ \t]+\[TODO (?<date>\d{4}-\d{2}-\d{2})\][ \t]+ルーティン:[ \t]*(?<task>.*?)[ \t]*$' -and
            $Matches.date -eq $DateText) {
            $recorded.Add(([string]$Matches.task).Trim()) | Out-Null
        }
    }

    return @($recorded)
}

# todo.mdのルーティンセクションに未登録のルーティンタスクを追加する。
function Update-MdhTodoRoutineSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$RoutineTasks,

        [AllowEmptyCollection()]
        [string[]]$RecordedRoutineTasks = @(),

        [ref]$AddedCount
    )

    $document = ConvertTo-MdhTodoLines -Content $Content
    $openBlock = $false
    $syntax = [regex]::Split((Get-MdhMarkdownSyntax -Content $Content -HasOpenBlock ([ref]$openBlock)), '\r\n|\n|\r')
    if ($openBlock) {
        Write-Warning 'todo.md に閉じていないMarkdownブロックがあるため、ルーティンを更新しません。'
        return $Content
    }

    $routineHeaders = @()
    $legacyHeadings = @()
    $presentTasks = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($index = 0; $index -lt $syntax.Count; $index++) {
        $line = $syntax[$index]
        if ($line -match '^###[ \t]+(?:ルーティン|やること)(?:[ \t]+#+)?[ \t]*$') {
            $legacyHeadings += $index
            $line = $line.Substring(1)
            $syntax[$index] = $line
        }
        if ($line -match '^##[ \t]+ルーティン(?:[ \t]+#+)?[ \t]*$') {
            $routineHeaders += $index
        }
        $checkbox = ConvertFrom-MdhTodoCheckbox -Line $line
        if ($checkbox) { $null = $presentTasks.Add($checkbox.Text) }
    }
    if ($routineHeaders.Count -gt 1) {
        Write-Warning 'todo.md のルーティン見出しが複数あるため、ルーティンを追加しません。'
        return $Content
    }

    foreach ($task in $RecordedRoutineTasks) { $null = $presentTasks.Add($task.Trim()) }
    $newTasks = foreach ($task in $RoutineTasks) {
        $normalized = $task.Trim()
        if ($normalized -and $presentTasks.Add($normalized)) { "- [ ] $normalized" }
    }
    if ($AddedCount) { $AddedCount.Value = if ($null -eq $newTasks) { 0 } else { @($newTasks).Count } }
    if ($routineHeaders.Count -eq 0) {
        $insertIndex = $document.Lines.Count
        $newTasks = @(
            if (-not [string]::IsNullOrWhiteSpace($document.Lines[-1])) { '' }
            '## ルーティン'
            $newTasks
        )
    }
    else {
        if (-not $newTasks) { return $Content }

        $routineStart = $routineHeaders[0]
        $insertIndex = $syntax.Count
        for ($index = $routineStart + 1; $index -lt $syntax.Count; $index++) {
            if ($syntax[$index] -match '^ {0,3}#{1,2}[ \t]+') {
                $insertIndex = $index
                break
            }
        }
        while ($insertIndex -gt $routineStart + 1 -and
            [string]::IsNullOrWhiteSpace($document.Lines[$insertIndex - 1])) {
            $insertIndex--
        }
        if ($insertIndex -gt $routineStart + 1) { $newTasks = @('') + @($newTasks) }
    }

    $updated = Edit-MdhTodoLines -Content $Content -Document $document -Start $insertIndex -Lines $newTasks
    $insertedLength = $updated.Length - $Content.Length
    for ($index = $legacyHeadings.Count - 1; $index -ge 0; $index--) {
        $heading = $legacyHeadings[$index]
        $offset = $document.Offsets[$heading]
        if ($heading -ge $insertIndex) { $offset += $insertedLength }
        $updated = $updated.Remove($offset, 1)
    }
    return $updated
}

# todo.mdから完了済みタスクを抽出し、所属セクションと行番号を取得する。
function Get-MdhTodoCompletedTasks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Content
    )

    $document = ConvertTo-MdhTodoLines -Content $Content
    $syntax = [regex]::Split((Get-MdhMarkdownSyntax -Content $Content), '\r\n|\n|\r')
    $tasks = [System.Collections.Generic.List[object]]::new()
    $currentSection = 'その他'
    $protectedUntil = 0

    for ($index = 0; $index -lt $document.Lines.Count; $index++) {
        $line = $syntax[$index]
        if ($line -match '^ {0,3}#{1,6}[ \t]+(?<heading>.+?)[ \t]*#*[ \t]*$') {
            $currentSection = [string]$Matches.heading
        }
        if ($index -lt $protectedUntil) { continue }

        $checkbox = ConvertFrom-MdhTodoCheckbox -Line $line
        if ($checkbox) {
            $indent = [regex]::Match($line, '^[ \t]*').Length
            $hasContinuation = $false
            $afterBlank = $false
            for ($next = $index + 1; $next -lt $syntax.Count; $next++) {
                $following = $document.Lines[$next]
                if ([string]::IsNullOrWhiteSpace($following)) {
                    $afterBlank = $true
                    continue
                }
                $nextIndent = [regex]::Match($following, '^[ \t]*').Length
                if ($nextIndent -le $indent -and ($afterBlank -or
                    $following -match '^[ \t]*(?:#{1,6}[ \t]+|(?:[-*+]|\d+[.)])[ \t]+|`{3,}|~{3,}|<!--|>|(?:-{3,}|\*{3,}|_{3,})[ \t]*$)')) {
                    break
                }
                $hasContinuation = $true
            }
            if ($hasContinuation -or $indent -ge 4 -or $line.StartsWith("`t")) {
                $protectedUntil = $next
                if ($checkbox.IsComplete) {
                    Write-Warning "TODO の $($index + 1) 行目は複数行またはインデント付きのため保持します。"
                }
                continue
            }
            if (-not $checkbox.IsComplete) { continue }
            $tasks.Add([pscustomobject]@{
                    LineIndex = $index
                    Text      = $checkbox.Text
                    Section   = $currentSection
                })
        }
    }

    return $tasks.ToArray()
}

# 完了済みタスクを日報の「やったこと」内の末尾にある「## done」へ記録する。
function Update-MdhDailyTodoCompletions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DailyPath,

        [Parameter(Mandatory)]
        [string]$DateText,

        [Parameter(Mandatory)]
        [object[]]$Tasks,

        [ref]$ArchivedCount
    )

    $dailyFile = Read-MdhDailyFile -Path $DailyPath -ErrorAction Stop
    $syntax = Get-MdhMarkdownSyntax -Content $dailyFile.Content
    $region = Get-MdhDailyTodoRegion -Syntax $syntax
    if (-not $region) {
        Write-Warning '日報の「# 🤖 自動入力」または配下の「## done」が一意に見つからないため、完了チェックを保持します。'
        return [pscustomobject]@{ Succeeded = $false }
    }

    $legacyEntries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($line in [regex]::Split((@(Get-MdhLegacyTodoHistory -Syntax $syntax -Region $region) -join "`n"), '\r\n|\n|\r')) {
        $null = $legacyEntries.Add($line.Trim())
    }

    $existingEntryCounts = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::Ordinal
    )
    $doneContent = $dailyFile.Content.Substring($region.Start, $region.End - $region.Start)
    $hasOpenBlock = $false
    $null = Get-MdhMarkdownSyntax -BodyOnly -Content $doneContent -HasOpenBlock ([ref]$hasOpenBlock)
    if ($hasOpenBlock) {
        Write-Warning '「## done」に閉じていないコードフェンスまたはコメントがあるため、完了チェックを保持します。'
        return [pscustomobject]@{ Succeeded = $false }
    }

    $doneRecords = [regex]::Replace($doneContent, '(?m)^ {0,3}<!--(?:(?!-->)[\s\S])*-->[ \t]*(?=\r?$)', '')
    foreach ($line in [regex]::Split($doneRecords, '\r\n|\n|\r')) {
        if ($line -match '^(?:[ \t]*| {0,3}(?:-(?:[ \t]*-){2,}|\*(?:[ \t]*\*){2,}|_(?:[ \t]*_){2,})[ \t]*)$') {
            continue
        }
        $completedOn = [datetime]::MinValue
        if ($line -cnotmatch '^- \[TODO (?<date>[0-9]{4}-[0-9]{2}-[0-9]{2})\] \S.*: .*\S[ \t]*$' -or
            -not [datetime]::TryParseExact($Matches.date, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$completedOn)) {
            Write-Warning '「## done」に完了履歴として識別できない行があるため、完了チェックを保持します。'
            return [pscustomobject]@{ Succeeded = $false }
        }
        $entry = $line.Trim()
        if (-not $existingEntryCounts.ContainsKey($entry)) {
            $existingEntryCounts[$entry] = 0
        }
        $existingEntryCounts[$entry]++
    }

    $requestedEntryCounts = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::Ordinal
    )
    $entriesToAdd = [System.Collections.Generic.List[string]]::new()
    foreach ($task in $Tasks) {
        $entry = "- [TODO $DateText] $($task.Section): $($task.Text)"
        if ($legacyEntries.Contains($entry)) {
            Write-Warning '旧形式の完了履歴に一致する記録があるため、転記せず完了チェックを保持します。'
            return [pscustomobject]@{ Succeeded = $false }
        }
        if (-not $requestedEntryCounts.ContainsKey($entry)) {
            $requestedEntryCounts[$entry] = 0
        }
        $requestedEntryCounts[$entry]++

        $existingCount = if ($existingEntryCounts.ContainsKey($entry)) {
            $existingEntryCounts[$entry]
        }
        else {
            0
        }
        if ($requestedEntryCounts[$entry] -gt $existingCount) {
            $entriesToAdd.Add($entry)
        }
    }

    if ($entriesToAdd.Count -eq 0) {
        return [pscustomobject]@{ Succeeded = $true }
    }

    $newline = $region.NewLine
    if (-not $newline) {
        $newline = if ($dailyFile.Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    }
    $trailingBlankLines = [regex]::Match($doneContent, '(?m)(?:^[ \t]*\r?\n)+\z')
    $insertAt = if ($trailingBlankLines.Success) {
        $region.Start + $trailingBlankLines.Index
    }
    else {
        $region.End
    }
    $insertion = $entriesToAdd -join $newline
    if ($insertAt -gt 0 -and $dailyFile.Content[$insertAt - 1] -ne "`n") {
        $insertion = $newline + $insertion
    }
    if ($insertAt -lt $dailyFile.Content.Length -or $dailyFile.Content.EndsWith("`n")) {
        $insertion += $newline
    }

    $updatedContent = $dailyFile.Content.Insert($insertAt, $insertion)
    Write-MdhDailyFile -Path $DailyPath -Content $updatedContent `
        -Utf8Bom:$dailyFile.HasUtf8Bom -ExpectedHash $dailyFile.Hash -ErrorAction Stop
    if ($ArchivedCount) { $ArchivedCount.Value = $entriesToAdd.Count }
    return [pscustomobject]@{ Succeeded = $true }
}

# 日報への記録が成功した完了済みタスクをtodo.mdから削除する。
function Remove-MdhTodoCompletedTasks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [object[]]$Tasks
    )

    $document = ConvertTo-MdhTodoLines -Content $Content
    foreach ($task in @($Tasks | Sort-Object LineIndex -Descending)) {
        $Content = Edit-MdhTodoLines -Content $Content -Document $document -Start $task.LineIndex -Count 1
    }
    return $Content
}


# todo.mdの初期Markdown本文を生成する。
function Get-MdhTodoInitialContent {
    $newline = [System.Environment]::NewLine
    return @(
        '# TODO'
        ''
        '## ルーティン'
        ''
        '## やること'
        ''
    ) -join $newline
}

# ルーティンの反映、完了タスクの日報記録、Quick Linksの更新を行い、todo.mdを開く。
function Update-MdhTodo {
    [CmdletBinding()]
    param(
        [string]$DateText,
        [switch]$NoOpen,
        [switch]$RequireArchive
    )

    $todoPath = Get-MdhTodoPath
    Write-Verbose "TODO の保存先を確認: $todoPath"
    $routinePath = Get-MdhTodoRoutinePath
    if ($todoPath -ieq $routinePath) {
        throw "todo.file と todo.routine_file に同じファイルは指定できません: $todoPath"
    }

    $dailyRoot = Get-MdhDailyRoot
    $dailyPrefix = [System.IO.Path]::GetFullPath($dailyRoot).TrimEnd('\') + '\'
    if ($todoPath.StartsWith($dailyPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "todo.file を日報保存先の配下には配置できません: $todoPath"
    }

    if (-not (Test-Path -LiteralPath $todoPath -PathType Leaf)) {
        if (Test-Path -LiteralPath $todoPath) {
            throw "todo.md の保存先にファイル以外が存在します: $todoPath"
        }

        Write-MdhTextFile `
            -Path $todoPath `
            -Content (Get-MdhTodoInitialContent) `
            -CreateNew `
            -Utf8Bom
    }

    $todoFile = Read-MdhTextFile -Path $todoPath
    $todoContent = $todoFile.Content
    $todayText = $DateText
    if (-not $todayText) {
        $todayText = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $latestDaily = Get-MdhLatestTodoDaily -BeforeOrOnDate $todayText
    $recordedRoutineTasks = @()

    if ($latestDaily) {
        $latestDailyContent = (Read-MdhDailyFile -Path $latestDaily.Path).Content
        $recordedRoutineTasks = @(Get-MdhRecordedRoutineTasks `
                -DailyContent $latestDailyContent `
                -DateText $todayText)
    }

    $routineAdded = 0
    $routineTasks = @(Get-MdhTodoRoutineTasks)
    $todoContent = Update-MdhTodoRoutineSection `
        -Content $todoContent `
        -RoutineTasks $routineTasks `
        -RecordedRoutineTasks $recordedRoutineTasks -AddedCount ([ref]$routineAdded) -WarningVariable routineWarnings

    $archivedCount = 0
    $archiveSucceeded = $true
    $completedTasks = @(Get-MdhTodoCompletedTasks -Content $todoContent)
    if ($completedTasks.Count -gt 0) {
        if (-not $latestDaily) {
            $archiveSucceeded = $false
            Write-Warning "日報がないため完了タスクを記録できません。チェックを保持します（$($completedTasks.Count)件）。日報を用意して再実行してください。"
        }
        else {
            $dailyResult = Update-MdhDailyTodoCompletions `
                -DailyPath $latestDaily.Path `
                -DateText $todayText `
                -Tasks $completedTasks -ArchivedCount ([ref]$archivedCount)
            $archiveSucceeded = $dailyResult.Succeeded
            if ($archiveSucceeded) {
                $todoContent = Remove-MdhTodoCompletedTasks `
                    -Content $todoContent `
                    -Tasks $completedTasks
            }
            else {
                Write-Host "todo | 転記を保留（チェック保持 $($completedTasks.Count) 件） | $todoPath。日報の `"## done`" と警告を確認してください。"
                if ($RequireArchive) { throw '完了タスクを日報に記録できなかったため、チェックを保持しました。' }
                if (-not $NoOpen) { Open-IfExist -Path $todoPath }
                return
            }
        }
    }

    if ($todoContent -cne $todoFile.Content) {
        Write-MdhTextFile `
            -Path $todoPath `
            -Content $todoContent `
            -Utf8Bom:$todoFile.HasUtf8Bom `
            -ExpectedHash $todoFile.Hash
    }

    Update-MdhQuickLinks -Path $todoPath -DateText $todayText -WarningVariable linkWarnings
    if ($RequireArchive -and -not $archiveSucceeded) {
        throw '完了タスクを日報に記録できなかったため、チェックを保持しました。'
    }
    $status = if ($archiveSucceeded -and -not ($routineWarnings -or $linkWarnings)) { '処理完了' } else { '警告付き完了' }
    $processed = if ($archiveSucceeded) { "新規転記 $archivedCount 件" } else { "チェック保持 $($completedTasks.Count) 件" }
    Write-Host "todo | $status | ルーティン追加 $routineAdded 件、$processed | $todoPath"
    if (-not $NoOpen) {
        Open-IfExist -Path $todoPath
    }
}

<#
.SYNOPSIS
TODOを整理して開きます。
.DESCRIPTION
ルーティンを補い、完了タスクを対象の日報へ転記し、Quick Links を更新します。
.EXAMPLE
todo
.NOTES
転記できなかった完了タスクのチェックは保持されます。
#>
function todo {
    [CmdletBinding()]
    param()

    Update-MdhTodo
}
