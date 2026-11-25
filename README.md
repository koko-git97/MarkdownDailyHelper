# Markdown Daily Helper (MDH)

**mdの自由度と構造化の両立を目指して、、、**
MDHは、Windows向けのMarkdownベースの日報・TODO・知識管理ツールです。
日々の記録を残すだけでなく、蓄積した情報を検索し、必要な形に再構成して活用することを目指しています。

## なぜMDHを作ったのか
学生時代、私はUbuntu × tmux × Emacsという環境で、ExcelやWordに極力頼らず研究活動を行っていました。いわゆるEmacs信者です、、、
尊敬する師匠がOrg modeを駆使して大規模な個人開発や研究進捗の管理を行う姿に憧れ、私も真似しようとしましたが、文法やEmacs Lispの難しさから、使いこなすには至りませんでした。

社会人になってからは、Excelとマクロを中心とした情報管理に不満を感じるようになりました。

- 検索性の低さ
- データ管理の煩雑さ
- Pythonなどによるデータ処理の手間
- 何より、マウス操作を前提としたUI

一方で、学生時代の環境を再現することも難しく、AIとの壁打ちを通じてVS CodeのEmacs風カスタマイズとMarkdownによる情報管理にたどり着きました。

かつてOrg modeで実現したかった情報管理環境を、自分なりの方法で作ろうと試行錯誤した結果、生まれたのがMDHです。

## MDHが目指すもの
目標は、日々の情報管理においてOneNoteやExcelを超えることです。
もちろん、あらゆる機能で競うつもりはありません。

日々の出来事や考えたことを、普通のMarkdownとして書き残す。
過去の記録が必要になれば、`mdsearch`で検索する。
特定のテーマについて蓄積した情報をまとめたければ、`mdrun`で集約する。

この2つのコマンドがMDHの肝です。
日々の記録を、単なる過去のメモではなく、将来も活用できる知識にしていきたいと考えています。

### 設計思想
- **書くときは自由に、使うときは構造的に。** 日々の記録に余計な手間をかけず、必要になったときに検索・集約する。
- **データはユーザーのもの。** Markdownを唯一の正本とし、SQLite索引は再生成可能なものとして扱う。MDHを使わなくなっても、記録は普通のMarkdownとして残る。

### 現在地とこれから
個人的には、日々のメモや知識の管理という用途において、MDHは既にExcelを使ったメモ管理を超えられたと感じています。
一方で、OneNoteを超えられたかと聞かれれば、まだそうは思いません。OneNoteの美しいUI、直感的な操作性、自由なレイアウトには、現状のMDHにはない魅力があります。
それでも、`mdsearch`と`mdrun`による情報の検索・再構成には、既存のメモ管理ツールとは異なる可能性を感じています。
OneNoteと同じものを作るのではなく、OneNoteとは異なる魅力を持ったツールを作りたい。そして、同じような悩みを持つ人にも使ってもらえるツールにしたい。

そんな思いで、現在も開発を行っています。

## 主な機能

| コマンド     | 機能                               |
| ------------ | ---------------------------------- |
| `daily`      | 日報の作成・更新・表示             |
| `todo`       | TODO管理と完了タスクの日報への記録 |
| `quicklinks` | Quick Linksの更新                  |
| `mdstart`    | 日報・TODO・DB処理の一括実行       |
| `md-db`      | SQLite索引の状態確認・同期・再構築 |
| `mdsearch`   | 日報・QuickNotesの検索             |
| `mdreverse`  | 日報からテーマに関連する情報を集約 |
| `mdrun`      | 設定したConceptに基づく日報の集約  |
| `mdversion`  | 製品バージョンの確認               |
| `mdlist`     | 有効設定・Concept・Typeの確認      |
| `mdhelp`     | コマンドのヘルプ表示               |

詳細は[コマンドリファレンス](30_docs/user/04_commands.md)を参照してください。

## 導入

WindowsとPowerShell 7.1以上が必要です。リポジトリのルートで実行してください。

```powershell
.\install.ps1 -WhatIf
.\install.ps1
```

初回導入後は新しいPowerShellを開き、`daily` と `todo` で最初の日報とTODOを作ります。
`mdstart` は日報、TODO、DBの順に処理します。ファイル表示を省くには `-NoOpen`、DB処理を省くには `-SkipDb` を指定します。
別のMDHがプロファイルに登録されている場合は既存登録を確認してください。一時セッションでの手動ロードは[導入ガイド](30_docs/user/01_getting-started.md)を参照してください。

## 保存先と検索

既定の保存先は本体配下の `01_Daily/`、`00_QuickNotes/`、`10_Aggregate/` です。
外部に分けるには `50_settings/config.json` の `paths.daily`、`paths.quicknotes`、`paths.aggregate` を設定します。
DBにはPython 3.10以上とSQLite 3.35以上が必要です。選んだPythonで次を実行します。

```powershell
python -m pip install -r .\40_scripts\py_scripts\mdh_db\requirements.txt
md-db -Rebuild
mdsearch '図書 CSV'
```

PythonはDaily・TODOの利用に不要です。VS CodeのCLIがないときは `mdstart -NoOpen` を使えます。
リンクやジャンクションを経由する保存先は導入時に拒否されることがあります。

## ガイドとテスト

[利用ガイド](30_docs/README.md)と[架空のサンプル](examples/README.md)を参照してください。
テストにはPesterと製品のPython依存が必要です。DB統合テストには `MDH_TEST_PYTHON_EXECUTABLE` にPythonの絶対パスを指定します。

```powershell
Invoke-Pester -Path .\tests\powershell
python -B -m unittest discover -s tests/python/mdh_db
```

ライセンスは[MIT](LICENSE)です。
