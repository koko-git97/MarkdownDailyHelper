[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$beginMarker = '# >>> MDH managed >>>'
$endMarker = '# <<< MDH managed <<<'
$changes = [Collections.Generic.List[string]]::new()
$stage = '前提確認'

function Get-FileStamp([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $item = Get-Item -LiteralPath $Path -Force
        return "$($item.LastWriteTimeUtc.Ticks):$((Get-FileHash -LiteralPath $Path).Hash)"
    }
    if (Test-Path -LiteralPath $Path) { throw "ファイルと競合しています: $Path" }
    return 'missing'
}

function Assert-NoReparsePoint([string]$Path) {
    $entry = [IO.Path]::GetFullPath($Path)
    while ($entry) {
        try {
            $attributes = [IO.File]::GetAttributes($entry)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "ReparsePoint を経由するパスは手動で確認してください: $entry"
            }
            if ($entry -ne $Path -and -not ($attributes -band [IO.FileAttributes]::Directory)) {
                throw "親パスがディレクトリではありません: $entry"
            }
        }
        catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
            # Continue checking existing ancestors of a missing destination.
        }
        $entry = [IO.Path]::GetDirectoryName($entry)
    }
}

function Publish-NewFile([string]$Path, [byte[]]$Bytes) {
    Assert-NoReparsePoint $Path
    $pending = Join-Path (Split-Path -Parent $Path) ([guid]::NewGuid().ToString() + '.tmp')
    try {
        $staging = [IO.File]::Open($pending, 'CreateNew', 'Write', 'None')
        try {
            $staging.Write($Bytes, 0, $Bytes.Length)
            $staging.Flush($true)
        }
        finally { $staging.Dispose() }
        Assert-NoReparsePoint $Path
        [IO.File]::Move($pending, $Path)
    }
    finally {
        if ([IO.File]::Exists($pending)) { [IO.File]::Delete($pending) }
    }
}

function Get-ProfileRegistration([string]$Path) {
    Assert-NoReparsePoint $Path
    $stamp = Get-FileStamp $Path
    $bytes = [byte[]]@()
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $offset = 0
    if ($stamp -ne 'missing') {
        if ((Get-Item -LiteralPath $Path -Force).LinkType -eq 'HardLink') {
            throw "ハードリンクされたプロファイルは手動で確認してください: $Path"
        }
        $bytes = [IO.File]::ReadAllBytes($Path)
        $prefix = [BitConverter]::ToString($bytes, 0, [Math]::Min(4, $bytes.Length))
        switch -Regex ($prefix) {
            '^(FF-FE-00-00|00-00-FE-FF)' { throw "未対応のUTF-32プロファイルです: $Path" }
            '^EF-BB-BF' { $offset = 3 }
            '^FF-FE' { $offset = 2; $encoding = [Text.UnicodeEncoding]::new($false, $false, $true) }
            '^FE-FF' { $offset = 2; $encoding = [Text.UnicodeEncoding]::new($true, $false, $true) }
        }
    }
    $content = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    if ($content.Contains([char]0) -or $content -match '(?m)^# SIG #') {
        throw "文字コードまたは署名を手動で確認してください: $Path"
    }
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "プロファイルに構文エラーがあります: $Path" }
    $markers = @($tokens | Where-Object {
        $_.Kind -eq 'Comment' -and $_.Text -match '^#\s*(>>>|<<<)\s*MDH\b'
    })
    if ($markers.Count -and ($markers.Count -ne 2 -or
            $markers[0].Text -cne $beginMarker -or $markers[1].Text -cne $endMarker -or
            $markers[0].Extent.StartColumnNumber -ne 1 -or $markers[1].Extent.StartColumnNumber -ne 1)) {
        throw "MDH管理マーカーが壊れています: $Path"
    }

    $registered = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and (
            $node.InvocationOperator -eq 'Dot' -or
            $node.GetCommandName() -match '\.ps1$' -or
            ($node.InvocationOperator -eq 'Ampersand' -and -not $node.GetCommandName())
        )
    }, $true) | ForEach-Object {
        $command = $_
        $name = $command.GetCommandName()
        if ($name -match '(?i)(^|[\\/])mdh\.ps1$') {
            if ($command.InvocationOperator -ne 'Dot' -or $command.CommandElements.Count -ne 1 -or
                -not [IO.Path]::IsPathFullyQualified($name) -or
                $command.Parent.Parent -ne $ast.EndBlock -or $ast.EndBlock.Unnamed -eq $false) {
                throw "MDH登録を静的に確定できません: $Path"
            }
            if ([IO.Path]::GetFullPath($name) -ne $loader) {
                throw "別のMDHが登録されています: $Path"
            }
            $command
        }
        elseif (-not $name) {
            throw "動的なスクリプト読み込みがあります。MDHの登録有無を手動で確認してください: $Path"
        }
        else {
            throw "別スクリプトを呼び出しています。MDHの登録有無を手動で確認してください: $Path ($name)"
        }
    })
    if ($markers.Count) {
        $bodyStart = $markers[0].Extent.EndOffset
        $body = $content.Substring($bodyStart, $markers[1].Extent.StartOffset - $bodyStart).Trim()
        if ($registered.Count -ne 1 -or $body -cne $registered[0].Extent.Text.Trim() -or
            $registered[0].Extent.StartOffset -lt $bodyStart -or
            $registered[0].Extent.EndOffset -gt $markers[1].Extent.StartOffset) {
            throw "MDH管理ブロックの内容を確認してください: $Path"
        }
    }
    if ((Get-FileStamp $Path) -ne $stamp) { throw "プロファイルが読み取り中に変更されました: $Path" }
    [pscustomobject]@{ Stamp = $stamp; Bytes = $bytes; Encoding = $encoding; Text = $content; Count = $registered.Count }
}

function Get-RegistrationPlan {
    $target = Get-ProfileRegistration $PROFILE.CurrentUserAllHosts
    $hostProfile = $null
    $count = $target.Count
    if ($PROFILE.CurrentUserCurrentHost -ne $PROFILE.CurrentUserAllHosts) {
        $hostProfile = Get-ProfileRegistration $PROFILE.CurrentUserCurrentHost
        $count += $hostProfile.Count
    }
    if ($count -gt 1) { throw 'MDHが複数登録されています。利用者用プロファイルを確認してください。' }
    [pscustomobject]@{ Target = $target; HostStamp = $hostProfile.Stamp; Add = ($count -eq 0) }
}

function New-ProfileContent($Snapshot) {
    $literal = "'" + $loader.Replace("'", "''") + "'"
    $newline = if ($Snapshot.Text -match '\r\n|\n|\r') { $Matches[0] } else { "`r`n" }
    $separator = if ($Snapshot.Text -and $Snapshot.Text -notmatch '[\r\n]$') { $newline } else { '' }
    $suffix = $separator + (@($beginMarker, ". $literal", $endMarker, '') -join $newline)
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput(
        ($Snapshot.Text + $suffix), [ref]$null, [ref]$errors)
    if ($errors.Count) { throw '追記後のプロファイルに構文エラーがあります。' }
    return $Snapshot.Bytes + $Snapshot.Encoding.GetBytes($suffix)
}

function Register-Profile([string]$Path, $Plan) {
    $snapshot = $Plan.Target
    $bytes = [byte[]](New-ProfileContent $snapshot)
    $current = Get-RegistrationPlan
    if (-not $current.Add -or $current.HostStamp -ne $Plan.HostStamp -or $current.Target.Stamp -ne $snapshot.Stamp) {
        throw '登録直前にプロファイルが変更されました。'
    }
    if ($snapshot.Stamp -eq 'missing') {
        Publish-NewFile $Path $bytes
        return
    }

    Assert-NoReparsePoint $Path
    # An exclusive Windows handle denies other opens, renames and replacement.
    # Keep it from the content check through append or rollback.
    $stream = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
    try {
        if ((Get-Item -LiteralPath $Path -Force).LinkType -eq 'HardLink') {
            throw "ハードリンクされたプロファイルは手動で確認してください: $Path"
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [Convert]::ToHexString($sha.ComputeHash($stream)) }
        finally { $sha.Dispose() }
        if ($hash -ne $snapshot.Stamp.Split(':')[-1]) {
            throw '書き込み直前にプロファイルが変更されたため、外部編集を保持しました。'
        }

        $backup = "$Path.mdh-$([guid]::NewGuid()).bak"
        Publish-NewFile $backup $snapshot.Bytes
        $changes.Add("プロファイルのバックアップ: $backup")
        $length = $snapshot.Bytes.Length
        $stream.Position = $length
        try {
            $stream.Write($bytes, $length, $bytes.Length - $length)
            $stream.Flush($true)
        }
        catch {
            $failure = $_.Exception.Message
            try {
                $stream.SetLength($length)
                $stream.Flush($true)
            }
            catch {
                throw "追記と復旧に失敗しました。バックアップを確認してください: $backup。$failure / $($_.Exception.Message)"
            }
            throw "追記に失敗したため、元のプロファイルを復元しました。$failure"
        }
    }
    finally { $stream.Dispose() }
}

try {
    if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion -lt [version]'7.1') {
        throw 'Windows の PowerShell 7.1 以上 (pwsh) を使用してください。'
    }
    $scripts = Join-Path $root '40_scripts/pwsh_scripts'
    $loader = Join-Path $scripts 'mdh.ps1'
    foreach ($name in @('mdh', 'mdh_common', 'mdh_init', 'mdh_daily', 'mdh_todo',
            'mdh_quicklinks', 'mdh_db', 'mdh_start', 'mdh_aggregate')) {
        if (-not (Test-Path -LiteralPath (Join-Path $scripts "$name.ps1") -PathType Leaf)) {
            throw "必須スクリプトがありません: $name.ps1"
        }
    }
    . (Join-Path $scripts 'mdh_init.ps1')
    . (Join-Path $scripts 'mdh_db.ps1')

    $configPath = Join-Path $root '50_settings/config.json'
    Assert-NoReparsePoint $configPath
    $templatePath = Join-Path $root '50_settings/config.template.json'
    $createConfig = (Get-FileStamp $configPath) -eq 'missing'
    $inputPath = if ($createConfig) { $templatePath } else { $configPath }
    foreach ($relative in @('50_settings/config.template.json', '50_settings/templates/DailyTemplate.md',
            '50_settings/templates/TodoRoutine.md', '40_scripts/py_scripts/mdh_db/__main__.py',
            '40_scripts/py_scripts/mdh_db/requirements.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf)) {
            throw "必須ファイルがありません: $relative"
        }
    }
    $inputStamp = Get-FileStamp $inputPath
    $config = Read-MdhConfiguration -MDHRoot $root -MDHConfig $inputPath
    $directoryPaths = @($config.paths.daily, $config.paths.quicknotes, $config.paths.aggregate)
    $missingDirectories = @($directoryPaths | Select-Object -Unique | Where-Object {
        if (Test-Path -LiteralPath $_ -PathType Container) { return $false }
        if ((Test-Path -LiteralPath $_) -or
            -not $_.StartsWith(($root.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw "保存先を手動で確認してください: $_"
        }
        Assert-NoReparsePoint $_
        $true
    })

    $stage = '環境診断'
    try {
        $settings = @{ Root = $root; Python = $null }
        if ($null -ne $config.db.python -and $config.db.python -isnot [string]) {
            throw 'db.python は文字列で指定してください。'
        }
        if ($config.db.python) {
            $settings.Python = Get-MdhDbAbsolutePath -Value $config.db.python -Root $root
        }
        if ($WhatIfPreference) {
            $candidates = if ($settings.Python) { $settings.Python } else {
                $venv = Join-Path $root '.venv/Scripts/python.exe'
                if (Test-Path -LiteralPath $venv -PathType Leaf) { $venv }
                Get-Command python.exe -All -CommandType Application -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Source
            }
            Write-Host "Python候補: $($candidates -join ', ')"
            Write-Host 'Pythonの起動・バージョン・依存関係の確認は通常実行時に行います。'
        }
        else {
            $python = Resolve-MdhDbPython -Settings $settings -SkipWindowsAppsAlias -IncludeEnvironment
            Write-Host "Python: $($python.Path) (Python $($python.Environment.python), SQLite $($python.Environment.sqlite))"
            Write-Host 'Python依存: 製品の requirements.txt と一致しています。'
        }
    }
    catch {
        Write-Warning "DB・検索・集約の利用にはPython環境の確認が必要です。$($_.Exception.Message)"
        Write-Warning 'db.python、PATH、製品の requirements.txt を確認してください。mdstart では -SkipDb を使用できます。'
    }
    if (-not (Get-Command code -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Warning 'VS Code の code CLI が見つかりません。mdstart で表示を省略するには -NoOpen を指定してください。'
    }

    $stage = 'プロファイル診断'
    $profilePath = $PROFILE.CurrentUserAllHosts
    $plan = Get-RegistrationPlan
    if ($plan.Add) {
        $null = New-ProfileContent $plan.Target
        $profileParent = Split-Path -Parent $profilePath
        if ((Test-Path -LiteralPath $profileParent) -and
            -not (Test-Path -LiteralPath $profileParent -PathType Container)) {
            throw "プロファイルの親がファイルです: $profileParent"
        }
        Write-Host "プロファイルディレクトリ: $profileParent (新規作成: $(-not (Test-Path -LiteralPath $profileParent)))"
        if ($plan.Target.Stamp -ne 'missing') { Write-Host "バックアップ: $profilePath.mdh-<識別子>.bak" }
    }
    Write-Host "MDH: $root"
    Write-Host "設定: $configPath (新規作成: $createConfig)"
    foreach ($directory in $directoryPaths) {
        Write-Host "保存先: $directory (新規作成: $($directory -in $missingDirectories))"
    }
    Write-Host "プロファイル: $profilePath (登録: $($plan.Add))"
    Write-Host "既存登録の確認先: $($PROFILE.CurrentUserCurrentHost)"
    if (-not $PSCmdlet.ShouldProcess($root, 'MDHセットアップを適用')) { return }

    $stage = '設定準備'
    if ($createConfig) {
        $bytes = [IO.File]::ReadAllBytes($templatePath)
        if ((Get-FileStamp $inputPath) -ne $inputStamp) { throw '設定テンプレートが変更されました。' }
        Publish-NewFile $configPath $bytes
        $changes.Add("設定を作成: $configPath")
    }
    elseif ((Get-FileStamp $configPath) -ne $inputStamp) { throw '設定が診断後に変更されました。' }
    $config = Read-MdhConfiguration -MDHRoot $root -MDHConfig $configPath
    $resolved = @($config.paths.daily, $config.paths.quicknotes, $config.paths.aggregate)
    if (@(Compare-Object $directoryPaths $resolved -SyncWindow 0).Count) {
        throw '保存先が診断時から変更されました。再実行してください。'
    }

    $stage = 'ディレクトリ準備'
    foreach ($directory in $missingDirectories) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            Assert-NoReparsePoint $directory
            $null = [IO.Directory]::CreateDirectory($directory)
            $changes.Add("ディレクトリを作成: $directory")
        }
    }

    $stage = 'ロード検証'
    $quotedLoader = "'" + $loader.Replace("'", "''") + "'"
    $verify = @"
`$ErrorActionPreference = 'Stop'
. $quotedLoader -RequireExisting
Get-Command daily, mdtoday, todo, quicklinks, mdstart, md-db, mdsearch, mdreverse, mdrun -CommandType Function -ErrorAction Stop | Out-Null
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($verify))
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -EncodedCommand $encoded
    if ($LASTEXITCODE -ne 0) { throw "MDHを読み込めませんでした (終了コード $LASTEXITCODE)。" }
    Write-Host 'ロード検証: 公開コマンドを確認しました。'

    $stage = 'プロファイル登録'
    $currentPlan = Get-RegistrationPlan
    if ($currentPlan.Target.Stamp -ne $plan.Target.Stamp -or $currentPlan.HostStamp -ne $plan.HostStamp -or
        $currentPlan.Add -ne $plan.Add) {
        throw 'プロファイルの状態が診断後に変更されました。再実行してください。'
    }
    if ($currentPlan.Add) {
        $parent = Split-Path -Parent $profilePath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            Assert-NoReparsePoint $parent
            $null = [IO.Directory]::CreateDirectory($parent)
            $changes.Add("ディレクトリを作成: $parent")
        }
        Register-Profile $profilePath $currentPlan
        $changes.Add("プロファイルへ登録: $profilePath")
    }

    $changes | ForEach-Object { Write-Host $_ }
    if ($changes.Count) { Write-Host '完了: 新しい PowerShell 7 セッションで MDH コマンドを確認してください。' }
    else { Write-Host '変更なし: 設定と登録を確認しました。' }
}
catch {
    $changes | ForEach-Object { Write-Host $_ }
    $status = if ($changes.Count) { '一部適用' } else { '要修正で停止' }
    throw "${status}: $stage。$($_.Exception.Message) 内容を確認し、install.ps1 -WhatIf で再診断してください。"
}
