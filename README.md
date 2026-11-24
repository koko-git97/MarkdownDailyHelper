# Markdown Daily Helper

Windows向けの日報・TODO・Markdown検索ツールです。Markdownはデータの正本で、SQLite索引は再生成できます。

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
