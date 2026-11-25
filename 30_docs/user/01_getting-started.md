# MDHの導入と初回確認

## はじめに

MDH は PowerShell から Markdown の日報とtodoを作成・更新して開くツールです。`md-db` と `mdsearch` で日報を索引化・検索できます。Markdownが唯一の正本であり、SQLite DBはMarkdownから再生成できる派生データです。

## 初期設定

### インストーラーで登録する

MDH本体を配置し、PowerShell 7.1以上でそのルートに移動します。

```powershell
.\install.ps1 -WhatIf
.\install.ps1
```

`-WhatIf` で設定・保存先・プロファイルの計画を確認します。このモードでは外部プログラムを起動せず、Pythonのバージョンや依存関係は通常実行時に確認します。通常実行では、不足している設定と許可されたディレクトリを作り、隔離プロセスでのロード確認後に現在のユーザーの AllHosts プロファイルへ登録します。既存設定と同じ本体への登録は保持されます。別の本体や判断できない登録があれば、表示されたプロファイルを確認してください。Pythonと VS Code は診断のみで、導入を続行できます。

新しい PowerShell 7 セッションで次を実行し、関数が表示されることを確認します。

```powershell
mdversion
mdhelp
```

一部適用の場合は表示された原因を解消し、同じ入口を再実行します。[プロファイルの復旧手順](05_troubleshooting.md#インストーラーが停止したとき)も参照してください。

### 起動スクリプトを手動で読み込む

Windows の PowerShell 7.6.10 で動作確認しています。PowerShell 7.1 が利用API上の下限で、7.1の実機検証は未実施です。一致語のANSI強調は対応端末とPowerShell 7.2以上で有効です。Windows PowerShell 5.1 は対象外です。リポジトリのルートに移動し、次を実行します。

```powershell
. .\40_scripts\pwsh_scripts\mdh.ps1
```

これはドットソースであり、関数を現在の PowerShell セッションに読み込みます。新しいセッションで利用するには再度実行してください。複数のセッションで使う場合は、上記のインストーラーで登録できます。

初回は `50_settings/config.json` が配布テンプレートから作成され、設定された保存先ディレクトリも必要に応じて作られます。初回ロードの後は、次のコマンドで利用者向け関数が読み込まれたことを確認できます。

```powershell
mdversion
mdhelp
```

[個人設定](02_configuration.md)で保存先を確認してから、[日常操作](03_daily-workflow.md)に進みます。`daily`、`todo`、`mdstart` はMarkdownを書き換えることがあるため、試用する場合は個人データを含まない作業コピーを使ってください。起動時のファイル表示にはVS Codeの `code` CLIが必要です。表示とDBを省略する指定は[コマンド一覧](04_commands.md)にあります。

### 既存環境を更新する

既存のMDH本体、利用者データ、PowerShellプロファイルをバックアップします。公開アーカイブは別フォルダーに展開します。既存の本体パスを維持し、新版の製品スクリプト、`install.ps1`、`VERSION`、ドキュメントを更新します。`50_settings/config.json`、日報、TODO、QuickNotesと既存の集約出力は保持してください。設定テンプレートや日報・ルーティンのテンプレートを利用者が変更している場合は、内容を比較して必要な変更を取り込んでください。

既存の本体ルートで `.\install.ps1 -WhatIf` を実行し、設定とプロファイルの扱いを確認します。続けて `.\install.ps1` を実行し、新しいPowerShellセッションで `mdversion` を確認します。同じ本体パスとDB保存先を維持した場合、既存の索引状態は `md-db -Status` で確認できます。索引が利用できない場合は、Markdownを保持したまま `md-db -Rebuild` で再生成できます。

## Python環境を用意する

DB機能のランタイム条件は Windows、Python 3.10以上、SQLite 3.35以上です。実機検証は Python 3.13 / PowerShell 7.6.10 で行っています。選択するPythonに、[製品用 requirements.txt](../../40_scripts/py_scripts/mdh_db/requirements.txt) の `markdown-it-py==3.0.0` と `mdurl==0.1.2` を導入します。既存環境への導入可否は環境の運用ルールに従ってください。

```powershell
# 準備した Python の絶対パスに置き換えて実行
& 'C:\path\to\python.exe' -m pip install -r .\40_scripts\py_scripts\mdh_db\requirements.txt
```

探索順は `db.python` で指定した実行ファイル、リポジトリの `.venv\Scripts\python.exe`、PATH上の `python.exe` です。venvは任意です。明示指定が不正な場合はエラーを返します。MDH操作時の自動インストールはありません。
