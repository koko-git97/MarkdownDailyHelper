# Daily log commands and helpers.

# 日時の変換と検証を行い、yyyy-MM-dd 形式の文字列を DateTime 型に変換
function ConvertTo-MdhDailyDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DateText
    )

    $date = [datetime]::MinValue
    $valid = [datetime]::TryParseExact(
        $DateText,
        'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$date
    )

    if (-not $valid) {
        throw "日付は yyyy-MM-dd 形式で指定してください: $DateText"
    }

    return $date.Date
}

# configから日報の保存先ディレクトリを取得
function Get-MdhDailyRoot {
    if (-not $script:MDH_CONFIG -or
        -not $script:MDH_CONFIG.paths -or
        [string]::IsNullOrWhiteSpace([string]$script:MDH_CONFIG.paths.daily)) {
        throw 'config.paths.daily が初期化されていません。MDH の初期化を実行してください。'
    }

    $dailyRoot = [System.IO.Path]::GetFullPath([string]$script:MDH_CONFIG.paths.daily)
    if (-not (Test-Path -LiteralPath $dailyRoot -PathType Container)) {
        throw "日報の保存先ディレクトリがありません: $dailyRoot"
    }

    return $dailyRoot
}

# 指定された日付の yyyy-MM-dd 形式の文字列に対応する日報ファイルのパスを取得
function Get-MdhDailyPath {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Alias('Date')]
        [string]$DateText = (Get-Date -Format 'yyyy-MM-dd')
    )

    $targetDate = ConvertTo-MdhDailyDate -DateText $DateText
    $dailyRoot = Get-MdhDailyRoot
    $year = $targetDate.ToString('yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
    $month = $targetDate.ToString('yyyy-MM', [System.Globalization.CultureInfo]::InvariantCulture)

    return Join-Path $dailyRoot (Join-Path $year (Join-Path $month "$DateText.md"))
}

# 既存の日報ファイルのうち、日付形式のファイル名を持つものを取得し、yyyy-MM-dd 形式の文字列として返す
function Get-MdhExistingDailyDates {
    $dailyRoot = Get-MdhDailyRoot
    $dates = foreach ($file in Get-ChildItem -LiteralPath $dailyRoot -Filter '*.md' -File -Recurse -ErrorAction Stop) {
        if ($file.BaseName -notmatch '^\d{4}-\d{2}-\d{2}$') {
            continue
        }

        try {
            $date = ConvertTo-MdhDailyDate -DateText $file.BaseName
        }
        catch {
            continue
        }

        # 年/月ディレクトリとファイル名が日付に一致するファイルだけを採用する。
        if ($file.FullName -ieq (Get-MdhDailyPath -DateText $file.BaseName)) {
            $date.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }

    return @($dates | Sort-Object -Unique)
}

# 指定された日付より前に存在する日報のうち、最も新しい日付を取得する
function Get-MdhLastDailyDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BeforeDate
    )

    $dateText = (ConvertTo-MdhDailyDate -DateText $BeforeDate).ToString(
        'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $dates = @(Get-MdhExistingDailyDates | Where-Object { $_ -lt $dateText } | Sort-Object -Descending)

    if ($dates.Count -gt 0) {
        return $dates[0]
    }

    return $null
}

# 指定された日付より後に存在する日報のうち、最も古い日付を取得する
function Get-MdhNextDailyDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AfterDate
    )

    $dateText = (ConvertTo-MdhDailyDate -DateText $AfterDate).ToString(
        'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $dates = @(Get-MdhExistingDailyDates | Where-Object { $_ -gt $dateText } | Sort-Object)

    if ($dates.Count -gt 0) {
        return $dates[0]
    }

    return $null
}

# 指定された日付文字列を基準に、対象日付と前後の日報の有無を確認
function Resolve-MdhDailyDate {
    [CmdletBinding()]
    param(
        [string]$DateText = (Get-Date -Format 'yyyy-MM-dd'),

        [switch]$Prev
    )

    $referenceDate = ConvertTo-MdhDailyDate -DateText $DateText
    $referenceDateText = $referenceDate.ToString(
        'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    if ($Prev) {
        $previousDateText = Get-MdhLastDailyDate -BeforeDate $referenceDateText
        if (-not $previousDateText) {
            Write-Warning "基準日 $referenceDateText より前の日報はありません。"
            return $null
        }

        $targetDate = ConvertTo-MdhDailyDate -DateText $previousDateText
    }
    else {
        $targetDate = $referenceDate
    }

    return [pscustomobject]@{
        TargetDate    = $targetDate
        ReferenceDate = $referenceDate
        IsPrevious    = [bool]$Prev
    }
}

# 指定された日付の前後リンクを取得
function Get-MdhDailyNavigation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime]$TargetDate,

        [string]$PreviousDate,

        [string]$NextDate
    )

    $links = [System.Collections.Generic.List[string]]::new()
    $targetPath = Get-MdhDailyPath -DateText $TargetDate.ToString('yyyy-MM-dd')
    $targetDirectory = Split-Path -Parent $targetPath

    foreach ($direction in @(
        [pscustomobject]@{ Arrow = '←'; DateText = $PreviousDate },
        [pscustomobject]@{ Arrow = '→'; DateText = $NextDate }
    )) {
        if ([string]::IsNullOrWhiteSpace($direction.DateText) -or
            $direction.DateText -eq $TargetDate.ToString('yyyy-MM-dd')) {
            continue
        }

        $linkedPath = Get-MdhDailyPath -DateText $direction.DateText
        $relativePath = [System.IO.Path]::GetRelativePath($targetDirectory, $linkedPath).Replace('\', '/')
        $links.Add("[$($direction.Arrow) $($direction.DateText)]($relativePath)")
    }

    return $links -join ' | '
}

# 予定の取得元がない場合は、取得成功の「予定なし」と区別する。
function Get-MdhDailyAppointments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime]$Date
    )

    # 予定の取得元がない場合は、取得成功の「予定なし」と区別する。
    return [pscustomobject]@{
        Status       = 'Unavailable'
        Appointments = @()
        Message      = '予定取得機能はまだ利用できません。'
    }
}

# 予定取得結果を標準化する。
function ConvertTo-MdhDailyAppointmentResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Result
    )

    $statusProperty = $Result.PSObject.Properties['Status']
    if (-not $statusProperty -or $statusProperty.Value -notin @('Available', 'Unavailable')) {
        throw '予定取得結果に有効な Status（Available / Unavailable）がありません。'
    }

    $messageProperty = $Result.PSObject.Properties['Message']
    $message = if ($messageProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$messageProperty.Value)) {
        [string]$messageProperty.Value
    }
    else {
        '予定を取得できませんでした。'
    }

    if ($statusProperty.Value -eq 'Unavailable') {
        return [pscustomobject]@{
            Status       = 'Unavailable'
            Appointments = @()
            Message      = $message
        }
    }

    $appointmentsProperty = $Result.PSObject.Properties['Appointments']
    if (-not $appointmentsProperty -or $null -eq $appointmentsProperty.Value) {
        throw '予定取得結果が Available ですが、Appointments がありません。'
    }

    return [pscustomobject]@{
        Status       = 'Available'
        Appointments = @($appointmentsProperty.Value)
        Message      = $message
    }
}

function Get-MdhDailyTemplatePath {
    $config = $script:MDH_CONFIG
    $templateValue = [string]$config.daily.template
    if ([string]::IsNullOrWhiteSpace($templateValue)) {
        throw 'config.daily.template が設定されていません。'
    }

    if ([System.IO.Path]::IsPathRooted($templateValue)) {
        $templateValue
    }
    else {
        if ([string]::IsNullOrWhiteSpace([string]$script:MDHRoot)) {
            throw '相対パスのテンプレートを解決するための MDHRoot が初期化されていません。'
        }
        Join-Path $script:MDHRoot $templateValue
    }
}

# テンプレートを基に日報の内容を生成
function New-MdhDailyContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime]$TargetDate,

        [string]$PreviousDate,

        [string]$NextDate,

        [string[]]$Appointments = @()
    )

    $templatePath = Get-MdhDailyTemplatePath

    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "日報テンプレートが見つかりません: $templatePath"
    }

    $template = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8 -ErrorAction Stop
    $requiredPlaceholders = @('{{DATE}}', '{{DOW}}', '{{NAVIGATION}}', '{{APPOINTMENTS}}')
    $missing = @($requiredPlaceholders | Where-Object { -not $template.Contains($_) })
    if ($missing.Count -gt 0) {
        throw "日報テンプレートに必須プレースホルダーがありません: $($missing -join ', ')"
    }

    $dateText = $TargetDate.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $dayOfWeek = $TargetDate.ToString(
        'ddd',
        [System.Globalization.CultureInfo]::GetCultureInfo('ja-JP')
    )
    $navigation = Get-MdhDailyNavigation `
        -TargetDate $TargetDate `
        -PreviousDate $PreviousDate `
        -NextDate $NextDate
    $syntax = Get-MdhMarkdownSyntax -Content $template
    $newline = if ($template.Contains("`r`n")) { "`r`n" } else { "`n" }
    $appointmentText = $Appointments -join $newline
    $startMarker = '<!-- MDH:APPOINTMENTS:START -->'
    $endMarker = '<!-- MDH:APPOINTMENTS:END -->'
    $appointmentHeadings = [regex]::Matches($syntax, '(?m)^[ ]{0,3}#{1,2}[ \t]+📅 今日の予定[ \t]*\r?$')
    $startMarkers = [regex]::Matches($syntax, "(?m)^$([regex]::Escape($startMarker))(?=\r?$)")
    $endMarkers = [regex]::Matches($syntax, "(?m)^$([regex]::Escape($endMarker))\r?$")
    if ($appointmentHeadings.Count -ne 1 -or
        $startMarkers.Count -ne 1 -or
        $endMarkers.Count -ne 1 -or
        $startMarkers[0].Index -ge $endMarkers[0].Index) {
        throw '日報テンプレートには予定見出しと予定管理マーカーをそれぞれ一意に指定してください。'
    }

    $section = Get-MdhAppointmentSection -Syntax $syntax -Heading $appointmentHeadings[0]
    if ($startMarkers[0].Index -le $section.Start -or
        $endMarkers[0].Index -ge $section.End) {
        throw '予定管理マーカーは予定見出しのセクション内に配置してください。'
    }

    $appointmentPlaceholder = $template.IndexOf('{{APPOINTMENTS}}', [System.StringComparison]::Ordinal)
    if ([regex]::Matches($template, [regex]::Escape('{{APPOINTMENTS}}')).Count -ne 1 -or
        $appointmentPlaceholder -le ($startMarkers[0].Index + $startMarkers[0].Length) -or
        $appointmentPlaceholder -ge $endMarkers[0].Index) {
        throw '予定プレースホルダーは予定管理マーカー内に1つだけ指定してください。'
    }

    $heading = [regex]::Match($syntax, '(?m)^[ ]{0,3}#{1,6}[ \t]+')
    $slot = [regex]::Match($syntax, '(?m)^\{\{NAVIGATION\}\}(?<newline>\r?\n)')
    if (-not $heading.Success -or -not $slot.Success -or $slot.Index -ge $heading.Index -or
        [regex]::Matches($template, '\{\{NAVIGATION\}\}').Count -ne 1) {
        throw '日報テンプレートの最初の見出しより前に {{NAVIGATION}} を1行だけ指定してください。'
    }
    if ($template -match 'MDH:NAVIGATION:') {
        $region = Get-MdhNavigationRegion -Syntax $syntax
        if (-not $region -or $region.InnerStart -ne $slot.Index -or $region.InnerLength -ne $slot.Length -or
            [regex]::Matches($template, '(?i)MDH:NAVIGATION:').Count -ne 2) {
            throw '旧ナビゲーションマーカーは {{NAVIGATION}} の前後に正しく配置してください。'
        }
        $template = $template.Remove($region.Start, $region.Length).Insert($region.Start, $slot.Value)
        $slot = [regex]::Match($template, '(?m)^\{\{NAVIGATION\}\}(?<newline>\r?\n)')
    }

    $navigationLine = if ($navigation) { $navigation + $slot.Groups['newline'].Value } else { '' }
    $template = $template.Remove($slot.Index, $slot.Length).Insert($slot.Index, $navigationLine)
    $content = $template.Replace('{{DATE}}', $dateText).
        Replace('{{DOW}}', $dayOfWeek).
        Replace('{{APPOINTMENTS}}', $appointmentText)

    if ($Appointments.Count -eq 0) {
        $emptyRegionPattern = "(?m)(^$([regex]::Escape($startMarker))\r?\n)\r?\n(?=^$([regex]::Escape($endMarker))\r?$)"
        $content = [regex]::Replace($content, $emptyRegionPattern, '$1')
    }

    return $content
}

# 既存日報のナビゲーションリンクを更新
function Update-MdhDailyNavigation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [datetime]$TargetDate,

        [string]$PreviousDate,

        [string]$NextDate
    )

    $navigation = Get-MdhDailyNavigation `
        -TargetDate $TargetDate `
        -PreviousDate $PreviousDate `
        -NextDate $NextDate
    $syntax = Get-MdhMarkdownSyntax -Content $Content
    $heading = [regex]::Match($syntax, '(?m)^[ ]{0,3}#{1,6}[ \t]+')
    $headerEnd = if ($heading.Success) { $heading.Index } else { $syntax.Length }
    $frontMatter = [regex]::Match($Content, '\A---[ \t]*\r?\n(?s:.*?)^(?:---|\.\.\.)[ \t]*\r?\n', 'Multiline')
    $header = $syntax.Substring(0, $headerEnd)
    $candidates = [regex]::Matches($header, '(?m)^[ \t]*\[(?:←|→)[^\r\n]*(?<newline>\r?\n|\z)')
    $markerLike = '(?im)^[ \t]*<!--[^\r\n]*MDH:NAVIGATION\b'
    $rawHeader = $Content.Substring($frontMatter.Length, $headerEnd - $frontMatter.Length)
    $dateText = $TargetDate.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)

    if ($syntax -match $markerLike -or $rawHeader -match $markerLike) {
        $region = Get-MdhNavigationRegion -Syntax $syntax
        if ($region -and [regex]::Matches($rawHeader, $markerLike).Count -eq 2 -and
            [string]::IsNullOrWhiteSpace($Content.Substring($frontMatter.Length, $region.Start - $frontMatter.Length))) {
            $inside = $Content.Substring($region.InnerStart, $region.InnerLength)
            $validLine = $inside -match '\r?\n\z' -and
                (Test-MdhDailyNavigationLine -Line ($inside -replace '\r?\n\z', '') -TargetDate $TargetDate)
            if (($inside.Length -eq 0 -or $validLine) -and
                $candidates.Count -eq [int]$validLine) {
                $replacement = if ($navigation) { $navigation + $region.NewLine } else { '' }
                return $Content.Remove($region.Start, $region.Length).Insert($region.Start, $replacement)
            }
        }
        Write-Warning "$dateText の旧ナビゲーション領域が不正または曖昧なため更新しません。"
    }
    elseif ($candidates.Count -gt 0) {
        $line = $candidates[0]
        $prefix = $Content.Substring($frontMatter.Length, $line.Index - $frontMatter.Length)
        $suffix = $Content.Substring($line.Index + $line.Length)
        if ($heading.Success -and $candidates.Count -eq 1 -and [string]::IsNullOrWhiteSpace($prefix) -and
            $suffix -notmatch '\A[ ]{0,3}(?:=+|-+)[ \t]*(?:\r?\n|\z)' -and
            (Test-MdhDailyNavigationLine -Line ($line.Value -replace '\r?\n\z', '') -TargetDate $TargetDate)) {
            $replacement = if ($navigation) { $navigation + $line.Groups['newline'].Value } else { '' }
            return $Content.Remove($line.Index, $line.Length).Insert($line.Index, $replacement)
        }
        Write-Warning "$dateText のナビゲーション行を安全に識別できないため更新しません。"
    }
    elseif ($navigation) {
        $weekday = $TargetDate.ToString('ddd', [cultureinfo]::GetCultureInfo('ja-JP'))
        $title = [regex]::Escape("# 🏷️ 作業ログ：$dateText（$weekday）")
        # The shipped template leaves one blank line on each side of the optional link.
        $slot = [regex]::Match($Content, "\A---\r?\ndate: $dateText\r?\ntitle:[^\r\n]*\r?\ntags:[^\r\n]*\r?\nprojects:[^\r\n]*\r?\n---\r?\n(?<newline>\r?\n)(?=\r?\n$title(?:\r?\n|\z))")
        if ($slot.Success) {
            return $Content.Insert($slot.Length, $navigation + $slot.Groups['newline'].Value)
        }
        Write-Warning "$dateText のナビゲーション挿入位置を安全に特定できないため更新しません。"
    }
    return $Content
}

function Test-MdhDailyNavigationLine {
    param([string]$Line, [datetime]$TargetDate)

    $pair = [regex]::Match($Line, '\A(?:\[← (?<previous>[0-9]{4}-[0-9]{2}-[0-9]{2})\]\([^)\r\n]+\)(?: \| (?=\[→)|(?=\z)))?(?:\[→ (?<next>[0-9]{4}-[0-9]{2}-[0-9]{2})\]\([^)\r\n]+\))?\z')
    if (-not $pair.Success -or $Line.Length -eq 0) { return $false }
    $previous = $pair.Groups['previous'].Value
    $next = $pair.Groups['next'].Value
    $dateText = $TargetDate.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    if (($previous -and $previous -ge $dateText) -or ($next -and $next -le $dateText)) { return $false }
    foreach ($date in $previous, $next) {
        $parsedDate = [datetime]::MinValue
        if ($date -and -not [datetime]::TryParseExact($date, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) { return $false }
    }
    $canonical = Get-MdhDailyNavigation -TargetDate $TargetDate -PreviousDate $previous -NextDate $next
    return [string]::Equals($Line, $canonical, [StringComparison]::Ordinal)
}

function Get-MdhNavigationRegion {
    param([string]$Syntax)

    $markers = [regex]::Matches($Syntax, '(?m)^<!-- MDH:NAVIGATION:(?<kind>START|END) -->[ \t]*(?<newline>\r?\n|\z)')
    if ($markers.Count -ne 2 -or $markers[0].Groups['kind'].Value -ne 'START' -or
        $markers[1].Groups['kind'].Value -ne 'END') {
        return
    }
    $heading = [regex]::Match($Syntax, '(?m)^[ ]{0,3}#{1,6}[ \t]+')
    if (-not $heading.Success -or $markers[1].Index -ge $heading.Index) {
        return
    }
    $start = $markers[0].Index + $markers[0].Length
    return [pscustomobject]@{
        Start = $markers[0].Index
        Length = $markers[1].Index + $markers[1].Length - $markers[0].Index
        InnerStart = $start
        InnerLength = $markers[1].Index - $start
        NewLine = $markers[0].Groups['newline'].Value
    }
}

function Get-MdhAppointmentSection {
    param(
        [string]$Syntax,
        [System.Text.RegularExpressions.Match]$Heading
    )

    $start = $Heading.Index
    $end = $Syntax.Length
    $legacyH1 = -not $Heading.Value.TrimStart().StartsWith('##')
    $headings = [regex]::Matches($Syntax, '(?m)^[ ]{0,3}(?<marks>#{1,2})[ \t]+(?<text>[^\r\n]*)')
    foreach ($next in $headings) {
        if ($next.Index -le $Heading.Index) {
            continue
        }
        if ($legacyH1 -and $next.Groups['marks'].Length -eq 2 -and
            $next.Groups['text'].Value.Trim() -ceq '自動取得') {
            $start = $next.Index
            $legacyH1 = $false
            continue
        }
        $end = $next.Index
        break
    }
    return [pscustomobject]@{ Start = $start; End = $end }
}

# 既存日報の予定セクションを更新
function Update-MdhDailyAppointments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [string[]]$Appointments = @('- 予定なし')
    )

    $syntax = Get-MdhMarkdownSyntax -Content $Content
    $headings = [regex]::Matches($syntax, '(?m)^[ ]{0,3}#{1,2}[ \t]+📅 今日の予定[ \t]*\r?$')
    $startMarker = '<!-- MDH:APPOINTMENTS:START -->'
    $endMarker = '<!-- MDH:APPOINTMENTS:END -->'
    $startMarkers = [regex]::Matches($syntax, "(?m)^$([regex]::Escape($startMarker))(?=\r?$)")
    $endMarkers = [regex]::Matches($syntax, "(?m)^$([regex]::Escape($endMarker))\r?$")
    if ($headings.Count -ne 1 -or $startMarkers.Count -ne 1 -or $endMarkers.Count -ne 1 -or
        $startMarkers[0].Index -ge $endMarkers[0].Index) {
        Write-Warning '予定見出しまたは自動管理領域が一意でないため、予定を更新しません。'
        return $Content
    }

    $section = Get-MdhAppointmentSection -Syntax $syntax -Heading $headings[0]
    if ($startMarkers[0].Index -le $section.Start -or $endMarkers[0].Index -ge $section.End) {
        Write-Warning '予定の自動管理領域が予定セクション内にないため、予定を更新しません。'
        return $Content
    }

    $bodyStart = $startMarkers[0].Index + $startMarkers[0].Length
    if ($Content.Substring($bodyStart).StartsWith("`r`n")) {
        $bodyStart += 2
    }
    elseif ($Content.Substring($bodyStart).StartsWith("`n")) {
        $bodyStart++
    }

    $newline = $Content.Substring($startMarkers[0].Index + $startMarkers[0].Length,
        $bodyStart - $startMarkers[0].Index - $startMarkers[0].Length)
    $replacement = if ($Appointments.Count -gt 0) { ($Appointments -join $newline) + $newline } else { '' }

    return $Content.Substring(0, $bodyStart) +
        $replacement +
        $Content.Substring($endMarkers[0].Index)
}

# daily本文を安全に書き込む
function Write-MdhDailyFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content,

        [switch]$CreateNew,

        [switch]$Utf8Bom,

        [string]$ExpectedHash
    )

    Write-MdhTextFile `
        -Path $Path `
        -Content $Content `
        -CreateNew:$CreateNew `
        -Utf8Bom:$Utf8Bom `
        -ExpectedHash $ExpectedHash `
        -Label '日報'
}

# 日報ファイルを読み込み、ファイル情報を取得する
function Read-MdhDailyFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return Read-MdhTextFile -Path $Path
}


# 指定された日付の日報を更新する。
# 新規作成の場合はテンプレートから生成し、既存の場合はナビゲーションリンクと予定欄を更新する。
function Update-MdhDailyFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime]$TargetDate,

        [string]$PreviousDate,

        [string]$NextDate,

        [switch]$NoOpen
    )

    $dailyFilePath = Get-MdhDailyPath -DateText $TargetDate.ToString('yyyy-MM-dd')
    Write-Verbose "日報の保存先を確認: $dailyFilePath"
    $isNewFile = -not (Test-Path -LiteralPath $dailyFilePath -PathType Leaf)
    if ($isNewFile -and (Test-Path -LiteralPath $dailyFilePath)) {
        throw "日報ファイルの保存先にファイル以外が存在します: $dailyFilePath"
    }

    if ($isNewFile) {
        $appointments = @()
        $appointmentResult = $null
        try {
            $appointmentResult = ConvertTo-MdhDailyAppointmentResult -Result (
                Get-MdhDailyAppointments -Date $TargetDate -ErrorAction Stop
            )
        }
        catch {
            Write-Warning "予定を取得できなかったため、新規日報の予定欄は空欄にします: $($_.Exception.Message)"
        }

        if ($appointmentResult.Status -eq 'Available') {
            $appointments = @($appointmentResult.Appointments)
            if ($appointments.Count -eq 0) {
                $appointments = @('- 予定なし')
            }
        }
        elseif ($appointmentResult) {
            Write-Warning ([string]$appointmentResult.Message)
        }

        $dailyContent = New-MdhDailyContent `
            -TargetDate $TargetDate `
            -PreviousDate $PreviousDate `
            -NextDate $NextDate `
            -Appointments $appointments
    }
    else {
        $originalFile = Read-MdhDailyFile -Path $dailyFilePath
        $originalContent = $originalFile.Content
        $dailyContent = $originalContent
        $dailyConfig = $script:MDH_CONFIG.daily

        if (-not $dailyConfig -or $dailyConfig.update_links -ne $false) {
            $dailyContent = Update-MdhDailyNavigation `
                -Content $dailyContent `
                -TargetDate $TargetDate `
                -PreviousDate $PreviousDate `
                -NextDate $NextDate
        }

        if (-not $dailyConfig -or $dailyConfig.update_schedule -ne $false) {
            try {
                $appointmentResult = ConvertTo-MdhDailyAppointmentResult -Result (
                    Get-MdhDailyAppointments -Date $TargetDate -ErrorAction Stop
                )
            }
            catch {
                Write-Warning "予定を取得できなかったため、既存の予定は変更しません: $($_.Exception.Message)"
                $appointmentResult = $null
            }

            if ($appointmentResult.Status -eq 'Available') {
                $appointments = @($appointmentResult.Appointments)
                $dailyContent = Update-MdhDailyAppointments `
                    -Content $dailyContent `
                    -Appointments $appointments
            }
            elseif ($appointmentResult) {
                Write-Warning ([string]$appointmentResult.Message)
            }
        }
    }

    $saveResult = '対象ファイルに変更なし'
    if ($isNewFile -or $dailyContent -cne $originalContent) {
        if ($isNewFile) {
            Write-MdhDailyFile -Path $dailyFilePath -Content $dailyContent -CreateNew -Utf8Bom
            $saveResult = '新規作成'
        }
        else {
            Write-MdhDailyFile `
                -Path $dailyFilePath `
                -Content $dailyContent `
                -Utf8Bom:$originalFile.HasUtf8Bom `
                -ExpectedHash $originalFile.Hash
            $saveResult = '更新'
        }
    }

    Write-Host "daily $($TargetDate.ToString('yyyy-MM-dd')) | $saveResult | $dailyFilePath"
    if (-not $NoOpen) {
        Open-IfExist -Path $dailyFilePath
    }
}

# 対象日と前後の日付を決定して日報処理を開始
function Start-MdhDaily {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Alias('Date')]
        [string]$DateText = (Get-Date -Format 'yyyy-MM-dd'),

        [switch]$Prev,

        [switch]$NoOpen
    )

    $resolvedDate = Resolve-MdhDailyDate -DateText $DateText -Prev:$Prev
    if ($null -eq $resolvedDate) {
        return
    }

    $targetDateText = $resolvedDate.TargetDate.ToString(
        'yyyy-MM-dd',
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $dates = @(Get-MdhExistingDailyDates)
    $earlier = @($dates | Where-Object { $_ -lt $targetDateText } | Select-Object -Last 2)
    $later = @($dates | Where-Object { $_ -gt $targetDateText } | Select-Object -First 2)
    $previousDate = $earlier | Select-Object -Last 1
    $nextDate = $later | Select-Object -First 1

    Update-MdhDailyFile `
        -TargetDate $resolvedDate.TargetDate `
        -PreviousDate $previousDate `
        -NextDate $nextDate `
        -NoOpen -ErrorAction Stop -WarningVariable dailyWarnings

    if ($script:MDH_CONFIG.daily.update_links -ne $false) {
        foreach ($neighbor in @(
            @{ Date = $previousDate; Previous = ($earlier | Select-Object -SkipLast 1); Next = $targetDateText }
            @{ Date = $nextDate; Previous = $targetDateText; Next = ($later | Select-Object -Skip 1) }
        )) {
            if (-not $neighbor.Date) { continue }
            try {
                $path = Get-MdhDailyPath -DateText $neighbor.Date
                $original = Read-MdhDailyFile -Path $path -ErrorAction Stop
                $content = Update-MdhDailyNavigation -Content $original.Content `
                    -TargetDate (ConvertTo-MdhDailyDate -DateText $neighbor.Date) `
                    -PreviousDate $neighbor.Previous -NextDate $neighbor.Next -ErrorAction Stop -WarningVariable +dailyWarnings
                if ($content -cne $original.Content) {
                    Write-MdhDailyFile -Path $path -Content $content -Utf8Bom:$original.HasUtf8Bom `
                        -ExpectedHash $original.Hash -ErrorAction Stop
                }
            }
            catch {
                throw "隣接日報 $($neighbor.Date) のナビゲーション更新に失敗しました。対象日報 $targetDateText は変更済みの場合があります。ファイルを確認してから再実行してください。$($_.Exception.Message)"
            }
        }
    }
    if (-not $NoOpen) {
        Open-IfExist -Path (Get-MdhDailyPath -DateText $targetDateText)
    }
    if ($dailyWarnings) { Write-Host "daily $targetDateText | 警告付き完了" }
}

<#
.SYNOPSIS
日報を作成または更新して開きます。
.DESCRIPTION
対象日の日報を準備し、設定に従って前後の日報のナビゲーションも更新します。
.PARAMETER DateText
対象日を yyyy-MM-dd で指定します。既定は今日です。Date は別名です。
.PARAMETER Prev
DateText より前に存在する最新の日報を対象とします。
.EXAMPLE
daily -DateText '2026-10-31' -Prev
.NOTES
対象日報の保存後に隣接日報の更新が失敗することがあります。
#>
function daily {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Alias('Date')]
        [string]$DateText = (Get-Date -Format 'yyyy-MM-dd'),

        [switch]$Prev
    )

    Start-MdhDaily -DateText $DateText -Prev:$Prev
}

<#
.SYNOPSIS
互換入口から日報を準備して開きます。
.DESCRIPTION
今日または指定した日の日報を作成・更新して開きます。
.PARAMETER DateText
対象日を yyyy-MM-dd で指定します。既定は今日です。Date は別名です。
.PARAMETER Open
互換用です。指定の有無にかかわらず日報を開きます。
.EXAMPLE
mdtoday -DateText '2026-10-31'
.NOTES
保存と表示の処理は daily と共通です。
#>
function mdtoday {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Alias('Date')]
        [string]$DateText = (Get-Date -Format 'yyyy-MM-dd'),

        [switch]$Open
    )

    Start-MdhDaily -DateText $DateText
}
