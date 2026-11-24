. (Join-Path $PSScriptRoot '..\..\40_scripts\pwsh_scripts\mdh_common.ps1')
. (Join-Path $PSScriptRoot '..\..\40_scripts\pwsh_scripts\mdh_daily.ps1')
. (Join-Path $PSScriptRoot '..\..\40_scripts\pwsh_scripts\mdh_todo.ps1')
. (Join-Path $PSScriptRoot '..\..\40_scripts\pwsh_scripts\mdh_quicklinks.ps1')

function Set-TestMdhTodoDaily {
    param(
        [Parameter(Mandatory)]
        [string]$DateText,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $path = Get-MdhDailyPath -DateText $DateText
    Ensure-Directory -Path (Split-Path -Parent $path)
    [System.IO.File]::WriteAllText(
        $path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
    return $path
}

Describe 'MDH todo functions' {
    BeforeEach {
        $testRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $dailyRoot = Join-Path $testRoot '01_Daily'
        $quicknotesRoot = Join-Path $testRoot '00_QuickNotes'
        $routinePath = Join-Path $testRoot 'TodoRoutine.md'
        Ensure-Directory -Path $dailyRoot
        Ensure-Directory -Path $quicknotesRoot
        [System.IO.File]::WriteAllText(
            $routinePath,
            "- [ ] 書架を確認する`n- [ ] 星形のしおりを作る",
            [System.Text.UTF8Encoding]::new($false)
        )

        $script:MDHRoot = $testRoot
        $script:MDH_CONFIG = [pscustomobject]@{
            paths = [pscustomobject]@{
                MDH_root  = $testRoot
                daily     = $dailyRoot
                quicknotes = $quicknotesRoot
            }
            todo = [pscustomobject]@{
                file = '{quicknotes}\00_TODO.md'
                routine_file = $routinePath
            }
            tasks = [pscustomobject]@{
                program = [pscustomobject]@{
                    rel_dir = '11_program'
                    mode = 'aggregate'
                }
            }
        }

        Mock Open-IfExist {}
    }

    It 'initializes todo.md and adds routines from the editable routine file' {
        todo

        $todoPath = Get-MdhTodoPath
        (Test-Path -LiteralPath $todoPath -PathType Leaf) | Should Be $true
        $content = [System.IO.File]::ReadAllText($todoPath)
        $content | Should Match '# TODO'
        ([regex]::Matches($content, '(?m)^## ルーティン\r?$')).Count | Should Be 1
        ([regex]::Matches($content, '(?m)^## やること\r?$')).Count | Should Be 1
        ([regex]::Matches($content, '- \[ \] 書架を確認する')).Count | Should Be 1
        ([regex]::Matches($content, '- \[ \] 星形のしおりを作る')).Count | Should Be 1
    }

    It 'ignores routine checkbox state and adds task definitions as unchecked items' {
        [System.IO.File]::WriteAllText(
            $routinePath,
            "- [x] チェック済み定義`n- [ ] 未チェック定義",
            [System.Text.UTF8Encoding]::new($false)
        )

        todo

        $content = [System.IO.File]::ReadAllText((Get-MdhTodoPath))
        $content | Should Match '- \[ \] チェック済み定義'
        $content | Should Match '- \[ \] 未チェック定義'
        $content | Should Not Match '- \[x\] チェック済み定義'
    }

    It 'does not duplicate routines when todo runs repeatedly and preserves manual tasks' {
        $path = Get-MdhTodoPath
        [System.IO.File]::WriteAllText(
            $path,
            "# TODO`n`n## ルーティン`n- [x] 書架を確認する`n- [ ] 手入力ルーティン`n`n## やること`n- [ ] 手入力タスク`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        todo
        todo

        $content = [System.IO.File]::ReadAllText($path)
        ([regex]::Matches($content, '書架を確認する')).Count | Should Be 1
        ([regex]::Matches($content, '星形のしおりを作る')).Count | Should Be 1
        $content | Should Match '- \[x\] 書架を確認する'
        $content | Should Match '- \[ \] 手入力ルーティン'
        $content | Should Match '- \[ \] 手入力タスク'
    }

    It 'does not add a routine when the same task already exists under another heading' {
        $todoPath = Get-MdhTodoPath
        [System.IO.File]::WriteAllText(
            $todoPath,
            "# TODO`n`n## やること`n- [x] 書架を確認する`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        todo

        $content = [System.IO.File]::ReadAllText($todoPath)
        ([regex]::Matches($content, '書架を確認する')).Count | Should Be 1
        ([regex]::Matches($content, '(?m)^## ルーティン\r?$')).Count | Should Be 1
        $content | Should Match '- \[x\] 書架を確認する'
    }

    It 'migrates a legacy level-three routine heading to level two' {
        $todoPath = Get-MdhTodoPath
        [System.IO.File]::WriteAllText(
            $todoPath,
            "# TODO`n`n### ルーティン`n- [x] 書架を確認する`n`n### やること`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        todo

        $content = [System.IO.File]::ReadAllText($todoPath)
        ([regex]::Matches($content, '(?m)^## ルーティン\r?$')).Count | Should Be 1
        ([regex]::Matches($content, '(?m)^### ルーティン\r?$')).Count | Should Be 0
        $content | Should Match '- \[ \] 星形のしおりを作る'
        $content | Should Match '- \[x\] 書架を確認する'
    }

    It 'ignores routine headings in fenced code blocks' {
        $content = @'
# TODO

```markdown
### ルーティン
```

## ルーティン

## やること
'@

        $updated = Update-MdhTodoRoutineSection -Content $content -RoutineTasks @('追加ルーティン')

        $updated | Should Match '```markdown\r?\n### ルーティン\r?\n```'
        $updated | Should Match '(?s)## ルーティン.*- \[ \] 追加ルーティン'
    }

    It 'does not modify todo when the routine heading is duplicated' {
        $content = "# TODO`n`n## ルーティン`n`n## ルーティン`n"

        $updated = Update-MdhTodoRoutineSection -Content $content -RoutineTasks @('追加ルーティン')

        $updated | Should Be $content
    }

    It 'adds changed routines without deleting routines already written in todo.md' {
        $todoPath = Get-MdhTodoPath
        [System.IO.File]::WriteAllText(
            $todoPath,
            "# TODO`n`n## ルーティン`n- [x] 旧ルーティン`n",
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::WriteAllText(
            $routinePath,
            "- [ ] 新ルーティン",
            [System.Text.UTF8Encoding]::new($false)
        )

        todo

        $content = [System.IO.File]::ReadAllText($todoPath)
        $content | Should Match '- \[x\] 旧ルーティン'
        $content | Should Match '- \[ \] 新ルーティン'
    }

    It 'keeps completed tasks in todo.md when no daily exists' {
        $path = Get-MdhTodoPath
        [System.IO.File]::WriteAllText(
            $path,
            "# TODO`n`n## やること`n- [x] 完了タスク`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        todo

        [System.IO.File]::ReadAllText($path) | Should Match '- \[x\] 完了タスク'
    }

    It 'does not treat checkbox examples in fenced code blocks as tasks' {
        $todayText = (Get-Date).ToString('yyyy-MM-dd')
        $dailyPath = Set-TestMdhTodoDaily -DateText $todayText -Content "# ✅ やったこと`n`n# 🤖 自動入力`n## done`n"
        $todoPath = Get-MdhTodoPath
        $content = @'
# TODO

## やること
- [x] 実際の完了タスク

```markdown
- [x] コード例
```
'@
        [System.IO.File]::WriteAllText($todoPath, $content, [System.Text.UTF8Encoding]::new($false))

        todo

        $updatedTodo = [System.IO.File]::ReadAllText($todoPath)
        $updatedTodo | Should Match '- \[x\] コード例'
        $updatedTodo | Should Not Match '- \[x\] 実際の完了タスク'
        [System.IO.File]::ReadAllText($dailyPath) | Should Match 'やること: 実際の完了タスク'
        [System.IO.File]::ReadAllText($dailyPath) | Should Not Match 'コード例'
    }

    It 'records completed tasks in the latest daily and removes them from todo.md' {
        $todayText = (Get-Date).ToString('yyyy-MM-dd')
        $dailyPath = Set-TestMdhTodoDaily -DateText $todayText -Content @'
# 作業ログ

# ✅ やったこと
- 手入力の日報記録

# 次のセクション
- 日報本文

# 🤖 自動入力
## done

## 別の自動入力
- 他の生成結果
'@
        $todoPath = Get-MdhTodoPath
        [System.IO.File]::WriteAllText(
            $todoPath,
            "# TODO`n`n## ルーティン`n- [x] 書架を確認する`n`n## 仕事`n- [x] 図書一覧の整理`n- [ ] 未完了タスク`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        todo

        $todoContent = [System.IO.File]::ReadAllText($todoPath)
        $todoContent | Should Not Match '図書一覧の整理'
        $todoContent | Should Not Match '書架を確認する'
        $todoContent | Should Match '- \[ \] 星形のしおりを作る'
        $todoContent | Should Match '- \[ \] 未完了タスク'

        $dailyContent = [System.IO.File]::ReadAllText($dailyPath)
        $dailyContent | Should Match '- \[TODO \d{4}-\d{2}-\d{2}\] ルーティン: 書架を確認する'
        $dailyContent | Should Match '- \[TODO \d{4}-\d{2}-\d{2}\] 仕事: 図書一覧の整理'
        $dailyContent | Should Match '- 手入力の日報記録'
        $dailyContent | Should Match '- 日報本文'
        $dailyContent | Should Match '(?s)# 🤖 自動入力\r?\n## done\r?\n- \[TODO .*\] ルーティン: 書架を確認する.*## 別の自動入力\r?\n- 他の生成結果'
    }

    It 'preserves existing work topics and writes only to the existing done subsection' {
        $todayText = (Get-Date).ToString('yyyy-MM-dd')
        $dailyPath = Set-TestMdhTodoDaily -DateText $todayText -Content @'
# ✅ やったこと
-
## 雲の図鑑
架空の雲を三種類描いた。

### 色見本
紫の色見本を追加した。

<!-- 合成テスト用のメモ -->

# 🤖 自動入力
## done
'@
        $tasks = @(
            [pscustomobject]@{
                Section = 'ルーティン'
                Text    = '星形のしおりを作る'
            }
        )

        Update-MdhDailyTodoCompletions -DailyPath $dailyPath -DateText $todayText -Tasks $tasks | Out-Null
        Update-MdhDailyTodoCompletions -DailyPath $dailyPath -DateText $todayText -Tasks @(
            $tasks
            [pscustomobject]@{
                Section = '仕事'
                Text    = '追加タスク'
            }
        ) | Out-Null

        $dailyContent = [System.IO.File]::ReadAllText($dailyPath)
        $dailyContent | Should Match '(?s)# ✅ やったこと.*## 雲の図鑑.*架空の雲を三種類描いた。.*### 色見本.*紫の色見本を追加した。.*<!-- 合成テスト用のメモ -->.*## done.*- \[TODO \d{4}-\d{2}-\d{2}\] ルーティン: 星形のしおりを作る.*- \[TODO \d{4}-\d{2}-\d{2}\] 仕事: 追加タスク'
        ([regex]::Matches($dailyContent, [regex]::Escape("- [TODO $todayText] ルーティン: 星形のしおりを作る"))).Count | Should Be 1
        ([regex]::Matches($dailyContent, [regex]::Escape("- [TODO $todayText] 仕事: 追加タスク"))).Count | Should Be 1
        ([regex]::Matches($dailyContent, [regex]::Escape('<!-- 合成テスト用のメモ -->'))).Count | Should Be 1
        ([regex]::Matches($dailyContent, '(?m)^## done\r?$')).Count | Should Be 1
        $dailyContent | Should Match '架空の雲を三種類描いた。'
        $dailyContent | Should Match '紫の色見本を追加した。'
    }

    It 'adds tasks without blank lines to an existing empty done subsection' {
        $todayText = (Get-Date).ToString('yyyy-MM-dd')
        $dailyPath = Set-TestMdhTodoDaily -DateText $todayText -Content @"
# ✅ やったこと

# 🤖 自動入力
## done

"@
        $tasks = @(
            [pscustomobject]@{
                Section = '仕事'
                Text    = 'タスク1'
            }
            [pscustomobject]@{
                Section = '仕事'
                Text    = 'タスク2'
            }
        )

        Update-MdhDailyTodoCompletions -DailyPath $dailyPath -DateText $todayText -Tasks $tasks | Out-Null

        $dailyContent = [System.IO.File]::ReadAllText($dailyPath)
        $dailyContent | Should Match "(?m)^## done\r?\n- \[TODO $todayText\] 仕事: タスク1\r?\n- \[TODO $todayText\] 仕事: タスク2"
        $dailyContent | Should Not Match "(?m)^## done\r?\n\r?\n- \[TODO"
        $dailyContent | Should Not Match "(?m)^- \[TODO $todayText\] 仕事: タスク1\r?\n\r?\n- \[TODO"
    }

    It 'records same-named tasks in different headings and preserves consecutive completion rows' {
        $todayText = (Get-Date).ToString('yyyy-MM-dd')
        $dailyPath = Set-TestMdhTodoDaily -DateText $todayText -Content "# ✅ やったこと`n`n# 🤖 自動入力`n## done`n"
        $todoPath = Get-MdhTodoPath
        [System.IO.File]::WriteAllText(
            $todoPath,
            "# TODO`n`n### 部署A`n- [x] 同名タスク`n- [x] 連続タスク1`n- [x] 連続タスク2`n- [ ] 未完了タスク`n`n### 部署B`n- [x] 同名タスク`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        todo

        $dailyContent = [System.IO.File]::ReadAllText($dailyPath)
        ([regex]::Matches($dailyContent, [regex]::Escape('部署A: 同名タスク'))).Count | Should Be 1
        ([regex]::Matches($dailyContent, [regex]::Escape('部署B: 同名タスク'))).Count | Should Be 1
        $dailyContent | Should Match '部署A: 連続タスク1'
        $dailyContent | Should Match '部署A: 連続タスク2'

        $todoContent = [System.IO.File]::ReadAllText($todoPath)
        $todoContent | Should Not Match '同名タスク|連続タスク1|連続タスク2'
        $todoContent | Should Match '- \[ \] 未完了タスク'
    }

    It 'preserves the occurrence count of identical completed tasks in one heading' {
        $todayText = (Get-Date).ToString('yyyy-MM-dd')
        $dailyPath = Set-TestMdhTodoDaily -DateText $todayText -Content "# ✅ やったこと`n`n# 🤖 自動入力`n## done`n"
        $todoPath = Get-MdhTodoPath
        [System.IO.File]::WriteAllText(
            $todoPath,
            "# TODO`n`n## やること`n- [x] 同じ項目`n- [x] 同じ項目`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        todo

        $entry = [regex]::Escape("- [TODO $todayText] やること: 同じ項目")
        ([regex]::Matches([System.IO.File]::ReadAllText($dailyPath), $entry)).Count | Should Be 2
        [System.IO.File]::ReadAllText($todoPath) | Should Not Match '同じ項目'
    }

    It 'does not re-add a routine already completed on the same day' {
        $todayText = (Get-Date).ToString('yyyy-MM-dd')
        Set-TestMdhTodoDaily -DateText $todayText -Content @"
# ✅ やったこと

# 🤖 自動入力
## done
- [TODO $todayText] ルーティン: 書架を確認する
"@ | Out-Null
        $todoPath = Get-MdhTodoPath
        [System.IO.File]::WriteAllText(
            $todoPath,
            "# TODO`n`n## ルーティン`n`n## やること`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        todo

        $content = [System.IO.File]::ReadAllText($todoPath)
        $content | Should Not Match '書架を確認する'
        $content | Should Match '- \[ \] 星形のしおりを作る'
    }

    It 'does not duplicate a daily record when retrying a completed task' {
        $todayText = (Get-Date).ToString('yyyy-MM-dd')
        $entry = "- [TODO $todayText] やること: 完了タスク"
        $dailyPath = Set-TestMdhTodoDaily -DateText $todayText -Content @"
# ✅ やったこと

# 🤖 自動入力
## done
$entry
"@
        $todoPath = Get-MdhTodoPath
        [System.IO.File]::WriteAllText(
            $todoPath,
            "# TODO`n`n## やること`n- [x] 完了タスク`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        todo

        $dailyContent = [System.IO.File]::ReadAllText($dailyPath)
        ([regex]::Matches($dailyContent, [regex]::Escape($entry))).Count | Should Be 1
        [System.IO.File]::ReadAllText($todoPath) | Should Not Match '- \[x\] 完了タスク'
    }

    It 'preserves existing daily content and skips ambiguous completion sections safely' {
        $todayText = (Get-Date).ToString('yyyy-MM-dd')
        $dailyPath = Set-TestMdhTodoDaily -DateText $todayText -Content @'
# ✅ やったこと
- 手入力記録
# ✅ やったこと
- 別の手入力記録
'@
        $todoPath = Get-MdhTodoPath
        [System.IO.File]::WriteAllText(
            $todoPath,
            "# TODO`n`n## やること`n- [x] 保留タスク`n",
            [System.Text.UTF8Encoding]::new($false)
        )
        $beforeDaily = [System.IO.File]::ReadAllBytes($dailyPath)

        todo

        [System.IO.File]::ReadAllBytes($dailyPath) | Should Be $beforeDaily
        [System.IO.File]::ReadAllText($todoPath) | Should Match '- \[x\] 保留タスク'
    }

    It 'transfers a task into a daily generated from the shipped template' {
        $todayText = (Get-Date).ToString('yyyy-MM-dd')
        $script:MDH_CONFIG | Add-Member -NotePropertyName daily -NotePropertyValue @{
            template = Join-Path $PSScriptRoot '..\..\50_settings\templates\DailyTemplate.md'
        }
        daily -DateText $todayText
        $dailyPath = Get-MdhDailyPath -DateText $todayText
        $before = Read-MdhTextFile -Path $dailyPath
        $todoPath = Get-MdhTodoPath
        $todoText = '# TODO', '## やること', '- [x] 生成直後のタスク' -join [Environment]::NewLine
        [IO.File]::WriteAllText($todoPath, $todoText)

        todo
        todo

        $after = Read-MdhTextFile -Path $dailyPath
        $after.HasUtf8Bom | Should Be $true
        $entry = [regex]::Escape("- [TODO $todayText] やること: 生成直後のタスク")
        $after.Content | Should Match "## done\r?\n$entry"
        ([regex]::Matches($after.Content, $entry)).Count | Should Be 1
        ([regex]::Replace($after.Content, "(?m)^$entry\r?\n", '')) | Should BeExactly $before.Content
        [IO.File]::ReadAllText($todoPath) | Should Not Match '生成直後のタスク'
    }

    It 'keeps completed tasks in todo.md when writing the daily fails' {
        $todayText = (Get-Date).ToString('yyyy-MM-dd')
        Set-TestMdhTodoDaily -DateText $todayText -Content "# ✅ やったこと`n`n# 🤖 自動入力`n## done`n" | Out-Null
        $todoPath = Get-MdhTodoPath
        [System.IO.File]::WriteAllText(
            $todoPath,
            "# TODO`n`n## やること`n- [x] 保留タスク`n",
            [System.Text.UTF8Encoding]::new($false)
        )
        Mock Write-MdhDailyFile { throw 'simulated daily write failure' }

        $failureReported = $false
        try {
            todo
        }
        catch {
            $failureReported = $true
        }

        $failureReported | Should Be $true
        [System.IO.File]::ReadAllText($todoPath) | Should Match '- \[x\] 保留タスク'
    }

    It 'does not duplicate daily entries when retrying after todo save fails' {
        $todayText = (Get-Date).ToString('yyyy-MM-dd')
        $dailyPath = Set-TestMdhTodoDaily -DateText $todayText -Content "# ✅ やったこと`n`n# 🤖 自動入力`n## done`n"
        $todoPath = Get-MdhTodoPath
        [System.IO.File]::WriteAllText(
            $todoPath,
            "# TODO`n`n## やること`n- [x] 再試行タスク`n- [x] 再試行タスク`n",
            [System.Text.UTF8Encoding]::new($false)
        )
        $script:todoPathForSaveFailure = $todoPath
        Mock Write-MdhDailyFile {
            [System.IO.File]::WriteAllText(
                $Path,
                $Content,
                [System.Text.UTF8Encoding]::new($Utf8Bom.IsPresent)
            )
            [System.IO.File]::AppendAllText(
                $script:todoPathForSaveFailure,
                "`n- concurrent edit",
                [System.Text.UTF8Encoding]::new($false)
            )
        }

        $failureReported = $false
        try {
            todo
        }
        catch {
            $failureReported = $true
        }

        $failureReported | Should Be $true
        [System.IO.File]::ReadAllText($todoPath) | Should Match '- \[x\] 再試行タスク'
        $dailyEntry = [regex]::Escape("- [TODO $todayText] やること: 再試行タスク")
        ([regex]::Matches([System.IO.File]::ReadAllText($dailyPath), $dailyEntry)).Count | Should Be 2

        todo

        ([regex]::Matches([System.IO.File]::ReadAllText($dailyPath), $dailyEntry)).Count | Should Be 2
        [System.IO.File]::ReadAllText($todoPath) | Should Not Match '再試行タスク'
        [System.IO.File]::ReadAllText($todoPath) | Should Match 'concurrent edit'
    }

    It 'refuses cross-section markers and marker examples without writing any bytes' {
        $path = Get-MdhTodoPath
        $start = '<!-- MDH:QUICKLINKS:START -->'
        $end = '<!-- MDH:QUICKLINKS:END -->'
        foreach ($source in @(
            "## 🔗 Quick Links`n$start`n## Tasks`n- [ ] 手入力`n$end"
            "~~~markdown`n$start`n例`n$end`n~~~"
            "<pre>`n$start`n例`n$end`n</pre>"
            "## 🔗 Quick Links`n$start`n### 手入力`n- 本文`n$end"
        )) {
            [IO.File]::WriteAllText($path, $source, [Text.UTF8Encoding]::new($true))
            $hash = (Get-FileHash -LiteralPath $path).Hash
            $warnings = @(Update-MdhQuickLinks -Path $path 3>&1)
            $warnings.Count | Should Be 1
            (Get-FileHash -LiteralPath $path).Hash | Should Be $hash
        }
    }

    It 'keeps commented and multiline tasks while archiving standalone tasks exactly once' {
        $day = Get-Date -Format yyyy-MM-dd
        $dailyPath = Set-TestMdhTodoDaily -DateText $day -Content "# ✅ やったこと`n`n# 🤖 自動入力`n## done`n"
        $path = Get-MdhTodoPath
        $protected = "<!--`n- [x] hidden`n-->`n`n- [x] parent`n`n  continuation`n  - [x] child"
        [IO.File]::WriteAllText($path, "# TODO`n`n$protected`n- [x] standalone`n")
        $output = (todo 3>&1) -join "`n"
        $output | Should Match '複数行'
        todo
        [IO.File]::ReadAllText($path).Contains($protected) | Should Be $true
        $history = [IO.File]::ReadAllText($dailyPath)
        $history | Should Not Match 'hidden|parent|continuation|child'
        ([regex]::Matches($history, 'standalone')).Count | Should Be 1
    }

    It 'refuses a Daily with only an HTML example, and Python recognizes completion in a real section' -Skip:(-not $env:MDH_TEST_PYTHON_EXECUTABLE) {
        $day = Get-Date -Format yyyy-MM-dd
        $sample = "# ✅ やったこと`n`n<pre>`n# 🤖 自動入力`n## done`n</pre>`n`n"
        $dailyPath = Set-TestMdhTodoDaily -DateText $day -Content $sample
        $path = Get-MdhTodoPath
        [IO.File]::WriteAllText($path, "# TODO`n`n- [x] parser integration`n")
        $before = (Get-FileHash -LiteralPath $dailyPath).Hash
        $todoBefore = (Get-FileHash -LiteralPath $path).Hash
        $failure = $null
        try { Update-MdhTodo -DateText $day -NoOpen -RequireArchive }
        catch { $failure = $_.Exception.Message }
        $failure | Should Match 'チェックを保持'
        (Get-FileHash -LiteralPath $dailyPath).Hash | Should Be $before
        (Get-FileHash -LiteralPath $path).Hash | Should Be $todoBefore
        [IO.File]::ReadAllText($path) | Should Match '\[x\] parser integration'
        [IO.File]::AppendAllText($dailyPath, "# 🤖 自動入力`n## done`n")
        Update-MdhTodo -DateText $day -NoOpen -RequireArchive
        $pythonRoot = Join-Path $PSScriptRoot '../../40_scripts/py_scripts'
        $result = & $env:MDH_TEST_PYTHON_EXECUTABLE -B -c 'import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); from mdh_db.parser import parse_daily; print(parse_daily(Path(sys.argv[2]).read_bytes()).completions[0].task)' $pythonRoot $dailyPath
        $LASTEXITCODE | Should Be 0
        $result | Should Be 'parser integration'
    }

    It 'preserves mixed line endings outside routine, completion and Quick Links edits' {
        $day = Get-Date -Format yyyy-MM-dd
        $null = Set-TestMdhTodoDaily -DateText $day -Content "# ✅ やったこと`n`n# 🤖 自動入力`n## done`n"
        $path = Get-MdhTodoPath
        $prefix = "# TODO`r`n`n手入力A`r`n手入力B`n`r`n"
        $suffix = "## Notes`n手入力C`r`n手入力D"
        $start = '<!-- MDH:QUICKLINKS:START -->'
        $end = '<!-- MDH:QUICKLINKS:END -->'
        $content = "$prefix## ルーティン`n`r`n## Tasks`r`n- [x] remove me`n- [ ] keep me`r`n`n## 🔗 Quick Links`r`n$start`n$end`r`n`n$suffix"
        [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($true))
        todo
        $result = Read-MdhTextFile -Path $path
        $result.HasUtf8Bom | Should Be $true
        $result.Content.StartsWith($prefix, [StringComparison]::Ordinal) | Should Be $true
        $result.Content.EndsWith("$end`r`n`n$suffix", [StringComparison]::Ordinal) | Should Be $true
        $result.Content.Contains("## Tasks`r`n- [ ] keep me`r`n`n## 🔗 Quick Links`r`n$start`n") | Should Be $true
        $result.Content | Should Match '書架を確認する'
        $result.Content | Should Not Match 'remove me'
        todo
        [IO.File]::ReadAllText($path) | Should BeExactly $result.Content
    }

    It 'promotes a legacy task heading when adding a missing routine section without new tasks' {
        $source = "### やること`r`n- [ ] 手入力"
        $updated = Update-MdhTodoRoutineSection -Content $source -RoutineTasks @()
        $updated | Should BeExactly "## やること`r`n- [ ] 手入力`r`n`r`n## ルーティン"
        (Update-MdhTodoRoutineSection -Content $updated -RoutineTasks @()) | Should BeExactly $updated
    }

    It 'keeps legacy headings when an existing routine section needs no update' {
        $source = "### ルーティン`r`n- [ ] existing`n### やること`n- [ ] 手入力"
        (Update-MdhTodoRoutineSection -Content $source -RoutineTasks @('existing')) | Should BeExactly $source
    }

    It 'inserts into empty and mixed-newline documents with a stable result on retry' {
        $empty = Update-MdhTodoRoutineSection -Content '' -RoutineTasks @('new')
        $empty | Should BeExactly ('## ルーティン' + [Environment]::NewLine + '- [ ] new')
        (Update-MdhTodoRoutineSection -Content $empty -RoutineTasks @('new')) | Should BeExactly $empty

        foreach ($ending in '', "`n") {
            $source = "## ルーティン`r`n## やること`n- [ ] 手入力$ending"
            $updated = Update-MdhTodoRoutineSection -Content $source -RoutineTasks @('new')
            $updated | Should BeExactly "## ルーティン`r`n- [ ] new`r`n## やること`n- [ ] 手入力$ending"
            (Update-MdhTodoRoutineSection -Content $updated -RoutineTasks @('new')) | Should BeExactly $updated
        }
    }

    It 'deletes the final task while preserving preceding line endings' {
        $prefix = "# TODO`r`n`n- [ ] 手入力`r`n"
        foreach ($ending in '', "`n", "`r`n") {
            $source = "$prefix- [x] final$ending"
            $tasks = @(Get-MdhTodoCompletedTasks -Content $source)
            $tasks.Count | Should Be 1
            $updated = Remove-MdhTodoCompletedTasks -Content $source -Tasks $tasks
            $updated | Should BeExactly $prefix
            @(Get-MdhTodoCompletedTasks -Content $updated).Count | Should Be 0
        }
        (Remove-MdhTodoCompletedTasks -Content '- [x] only' -Tasks @(@{ LineIndex = 0 })) | Should BeExactly ''
    }

    It 'updates only the Quick Links managed block and leaves task checkboxes unchanged' {
        $todoPath = Get-MdhTodoPath
        [System.IO.File]::WriteAllText(
            $todoPath,
            "# TODO`n`n## やること`n- [ ] 手入力タスク`n`n## 🔗 Quick Links`n- 手入力リンク`n",
            [System.Text.UTF8Encoding]::new($false)
        )
        Set-TestMdhTodoDaily -DateText (Get-Date -Format 'yyyy-MM-dd') -Content "# ✅ やったこと`n" | Out-Null
        $programIndex = Join-Path $script:MDHRoot (Join-Path (Get-Date -Format 'yyyy') '11_program\index.md')
        Ensure-Directory -Path (Split-Path -Parent $programIndex)
        [System.IO.File]::WriteAllText($programIndex, '# Program')

        Update-MdhQuickLinks -Path $todoPath
        $first = [System.IO.File]::ReadAllText($todoPath)
        Update-MdhQuickLinks -Path $todoPath
        $second = [System.IO.File]::ReadAllText($todoPath)

        $second | Should Match '- \[ \] 手入力タスク'
        $second | Should Match '- 手入力リンク'
        $second | Should Match '\[完了タスクの記録\]\(.*01_Daily/.*\.md\)'
        $second | Should Match '\[program\]\(.*11_program/index\.md\)'
        ([regex]::Matches($second, '<!-- MDH:QUICKLINKS:START -->')).Count | Should Be 1
        $second | Should Be $first
    }

    It 'keeps completed tasks when the latest daily is legacy or its new destination is ambiguous' {
        $todayText = (Get-Date).ToString('yyyy-MM-dd')
        $todoPath = Get-MdhTodoPath
        $todoText = "# TODO`n## やること`n- [x] 保留タスク`n"
        $cases = @(
            "# ✅ やったこと`n## done`n- 旧履歴`n"
            "# 🤖 自動入力`n## 別の領域`n"
            "# 🤖 自動入力`n## done`n## done`n"
            "# 🤖 自動入力`n## done`n# 🤖 自動入力`n"
            "# 🤖 自動入力`n## done`n~~~markdown`nexample`n"
            "# ✅ やったこと`n# 🤖 自動入力`n## done`n~~~markdown`nexample`n~~~`n"
            "# ✅ やったこと`n# 🤖 自動入力`n## done`n手入力メモ`n"
            "# ✅ やったこと`n# 🤖 自動入力`n## done`n- [todo $todayText] 仕事: 例`n"
            "<!--`n# 🤖 自動入力`n## done`n-->`n"
            "# 🤖 自動入力`n## done`n<!--`n未終了コメント`n"
        )
        foreach ($content in $cases) {
            $dailyPath = Set-TestMdhTodoDaily -DateText $todayText -Content $content
            [IO.File]::WriteAllText($todoPath, $todoText)
            todo -WarningVariable warnings
            $warnings.Count | Should Be 1
            [IO.File]::ReadAllText($dailyPath) | Should BeExactly $content
            [IO.File]::ReadAllText($todoPath) | Should Match '- \[x\] 保留タスク'
        }
    }

    It 'keeps both files when the same completion appears in legacy and new history' {
        $todayText = (Get-Date).ToString('yyyy-MM-dd')
        $entry = "- [TODO $todayText] やること: 保留タスク"
        $content = "# ✅ やったこと`n## done`n$entry`n# 🤖 自動入力`n## done`n$entry`n"
        $dailyPath = Set-TestMdhTodoDaily -DateText $todayText -Content $content
        $todoPath = Get-MdhTodoPath
        [IO.File]::WriteAllText($todoPath, "# TODO`n## やること`n- [x] 保留タスク`n")

        todo -WarningVariable warnings

        $warnings.Count | Should Be 1
        [IO.File]::ReadAllText($dailyPath) | Should BeExactly $content
        [IO.File]::ReadAllText($todoPath) | Should Match '- \[x\] 保留タスク'
    }

    It 'preserves the BOM, front matter and original mixed line endings around done' {
        $todayText = (Get-Date).ToString('yyyy-MM-dd')
        $prefix = "---`r`ntitle: '手入力'`r`n---`r`n# ✅ やったこと`n## Topic`n本文`n# 🤖 自動入力`r`n## done`r`n"
        $suffix = "`r`n## 別の領域`n- 手入力"
        $dailyPath = Set-TestMdhTodoDaily -DateText $todayText -Content ($prefix + $suffix)
        [IO.File]::WriteAllText($dailyPath, $prefix + $suffix, [Text.UTF8Encoding]::new($true))
        $tasks = @([pscustomobject]@{ Section = '仕事'; Text = '検証' })

        Update-MdhDailyTodoCompletions -DailyPath $dailyPath -DateText $todayText -Tasks $tasks | Out-Null

        $file = Read-MdhTextFile -Path $dailyPath
        $file.HasUtf8Bom | Should Be $true
        $file.Content | Should BeExactly ($prefix + "- [TODO $todayText] 仕事: 検証`r`n" + $suffix)
    }
}
