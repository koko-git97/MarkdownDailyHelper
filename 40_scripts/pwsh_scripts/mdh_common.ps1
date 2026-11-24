# ファイルに行を書き込み、UTF-8（BOM付き）で保存する。
function Write-Utf8 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllLines($Path, $Content, $encoding)
}

# ディレクトリが存在しない場合は作成する。パスがファイルを指している場合はエラーを投げる。
function Ensure-Directory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        throw "ディレクトリとして使用するパスにファイルが存在します: $Path"
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
    }
}

# UTF-8 Markdownファイルを厳密に読み込み、同時変更検知に使う情報を返す。
function Read-MdhTextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasUtf8Bom = $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasUtf8Bom) { 3 } else { 0 }
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    $content = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    $hash = [BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::HashData($bytes)
    ).Replace('-', '')

    return [pscustomobject]@{
        Content    = $content
        HasUtf8Bom = $hasUtf8Bom
        Hash       = $hash
    }
}

# UTF-8 Markdownファイルを一時ファイル経由で保存し、既存内容の競合を拒否する。
function Get-MdhMarkdownMutexName {
    param([string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($IsWindows) { $fullPath = $fullPath.ToUpperInvariant() }
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fullPath)))
    return "Global\MDH.Markdown.$digest"
}

function Write-MdhTextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content,

        [switch]$CreateNew,

        [switch]$Utf8Bom,

        [string]$ExpectedHash,

        [string]$Label = 'Markdownファイル'
    )

    $directory = Split-Path -Parent $Path
    Ensure-Directory -Path $directory

    if (-not $CreateNew -and [string]::IsNullOrWhiteSpace($ExpectedHash)) {
        throw "既存${Label}の安全な更新に必要な ExpectedHash が指定されていません。"
    }

    $temporaryPath = Join-Path $directory ('.{0}.{1}.tmp' -f `
        [System.IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
    $encoding = [System.Text.UTF8Encoding]::new($Utf8Bom.IsPresent)
    $mutex = [Threading.Mutex]::new($false, (Get-MdhMarkdownMutexName -Path $Path))
    $ownsMutex = $false

    try {
        try {
            $ownsMutex = $mutex.WaitOne([TimeSpan]::FromSeconds(15))
        }
        catch [Threading.AbandonedMutexException] {
            # The OS transferred ownership. Recheck the destination before writing.
            $ownsMutex = $true
        }
        if (-not $ownsMutex) { throw "${Label}の別プロセスによる保存が完了しないため中止しました: $Path" }
        [System.IO.File]::WriteAllText($temporaryPath, $Content, $encoding)
        if ($CreateNew) {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
        else {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                throw "更新対象の${Label}が見つかりません: $Path"
            }

            $targetStream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::Read
            )
            try {
                $currentHash = [BitConverter]::ToString(
                    [System.Security.Cryptography.SHA256]::HashData($targetStream)
                ).Replace('-', '')
            }
            finally {
                $targetStream.Dispose()
            }

            if ($currentHash -ne $ExpectedHash) {
                throw "${Label}が読み込み後に変更されたため、上書きを中止しました: $Path"
            }

            [System.IO.File]::Move($temporaryPath, $Path, $true)
        }
    }
    finally {
        try {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
            }
        }
        finally {
            if ($ownsMutex) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
}

# VS Codeが利用可能な場合は、既存のファイルまたはディレクトリをVS Codeで開く。
# 利用できない場合は、OSの既定のアプリケーションで開く。
# パスが存在しない場合は、意図的に何もせず処理を終了する。
function Open-IfExist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$RequireCode
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($RequireCode) {
            throw "起動直前に表示対象が見つかりません: $Path"
        }
        return
    }

    if ($RequireCode) {
        $code = Get-Command code -CommandType Application -TotalCount 1 -ErrorAction SilentlyContinue
        if (-not $code) {
            throw 'VS Code の code コマンドが見つかりません。'
        }
        # Wait for the CLI to submit each request before issuing the next one.
        & $code.Source --reuse-window $Path | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "VS Code の起動要求に失敗しました（終了コード $LASTEXITCODE）。"
        }
    }
    elseif (Get-Command code -ErrorAction SilentlyContinue) {
        Start-Process -FilePath code -ArgumentList ('"{0}"' -f $Path) -ErrorAction Stop
    }
    else {
        Start-Process -FilePath $Path -ErrorAction Stop
    }
}

# Markdownのコードフェンス行を判定し、フェンス内外の状態を更新する。
function Test-MdhMarkdownFenceLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Line,

        [Parameter(Mandatory)]
        [hashtable]$State
    )

    if ($State.Inside) {
        if ($Line -match '^[ \t]{0,3}(?<fence>`{3,}|~{3,})[ \t]*$' -and
            $Matches.fence[0] -eq $State.Character -and
            $Matches.fence.Length -ge $State.Length) {
            $State.Inside = $false
            $State.Character = ''
            $State.Length = 0
        }
        return $true
    }

    if ($Line -match '^[ \t]{0,3}(?<fence>`{3,}|~{3,}).*$') {
        $State.Inside = $true
        $State.Character = $Matches.fence[0]
        $State.Length = $Matches.fence.Length
        return $true
    }

    return $false
}

# 更新対象の探索から front matter、コードフェンス、複数行コメントを除外し、原文の位置を維持する。
function Get-MdhMarkdownSyntax {
    param([string]$Content, [switch]$BodyOnly, [ref]$HasOpenBlock)

    $state = @{ Inside = $false; Character = ''; Length = 0 }
    $state.FrontMatter = -not $BodyOnly -and $Content -match '\A---[ \t]*(?:\r\n|\n|\r)'
    $state.Comment = $false
    $state.HtmlEnd = ''
    $state.HtmlUntilBlank = $false
    $syntax = [regex]::Replace($Content, '(?<line>[^\r\n]*)(?<end>\r\n|\r|\n|\z)', {
        param($match)

        $line = $match.Groups['line'].Value
        $end = $match.Groups['end'].Value
        $masked = (' ' * $line.Length) + $end
        if ($state.FrontMatter) {
            if ($match.Index -gt 0 -and $line -match '^(?:---|\.\.\.)[ \t]*$') {
                $state.FrontMatter = $false
            }
            return $masked
        }
        if ($state.Comment) {
            $state.Comment = -not $line.Contains('-->')
            return $masked
        }
        if ($state.HtmlEnd) {
            if ($line -match $state.HtmlEnd) { $state.HtmlEnd = '' }
            return $masked
        }
        if ($state.HtmlUntilBlank) {
            if ([string]::IsNullOrWhiteSpace($line)) { $state.HtmlUntilBlank = $false }
            return $masked
        }
        if (Test-MdhMarkdownFenceLine -Line $line -State $state) {
            return $masked
        }
        $html = switch -Regex ($line) {
            '^ {0,3}<(pre|script|style|textarea)(?:[ \t>]|$)' { "</$($Matches[1])>"; break }
            '^ {0,3}<\?' { '\?>'; break }
            '^ {0,3}<!\[CDATA\[' { '\]\]>'; break }
            '^ {0,3}<![A-Z]' { '>'; break }
        }
        if ($html) {
            if ($line -notmatch $html) { $state.HtmlEnd = $html }
            return $masked
        }
        if ($line -match '^ {0,3}</?[A-Za-z][A-Za-z0-9-]*(?:[ \t/>]|$)') {
            $state.HtmlUntilBlank = $true
            return $masked
        }
        $unclosedComment = ($line -replace '<!--.*?-->', '').Contains('<!--')
        if ($unclosedComment) {
            $state.Comment = $true
            return $masked
        }
        return $match.Value
    })
    if ($HasOpenBlock) {
        $HasOpenBlock.Value = $state.Inside -or $state.Comment -or $state.FrontMatter -or [bool]$state.HtmlEnd
    }
    return $syntax
}
