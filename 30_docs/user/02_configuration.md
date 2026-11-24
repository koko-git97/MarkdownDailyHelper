# MDHの個人設定

編集するファイルは `50_settings/config.json` です。初回のひな形は [config.template.json](../../50_settings/config.template.json) にあります。既存の個人設定は、ひな形の更新時にもそのまま残ります。WindowsパスをJSON文字列に書く場合は、例のように逆斜線を二重にします。

## 個人設定を整える

初回読み込み時、`50_settings/config.json` がなければ `50_settings/config.template.json` から作成されます。この JSON は個人設定で、Git 管理対象外です。

初期設定で特に確認する項目:

| 設定 | 設定内容 |
|---|---|
| `paths.MDH_root` | 空欄なら読み込んだリポジトリのルートを使う。値を入れる場合は実際のルートと一致させる |
| `paths.daily` | 空欄ならリポジトリ内の `01_Daily`。必要なら日報保存先を指定 |
| `paths.quicknotes` | 空欄なら `00_QuickNotes`。既定のTODOの親ディレクトリ |
| `paths.aggregate` | 空欄なら `10_Aggregate`。Concept集約とindexの保存先 |
| `daily.template` | 実在するテンプレートを指定。現在のファイルは `50_settings\templates\DailyTemplate.md` |
| `daily.update_links` | 既存日報の前後リンク更新を制御 |
| `daily.update_schedule` | 既存日報の予定取得・管理領域更新を制御 |
| `todo.file` | todoファイルの保存先。既定は `{quicknotes}\00_TODO.md` |
| `todo.routine_file` | ルーティン元ファイル。既定は `50_settings\templates\TodoRoutine.md` |

新しく作成される `config.json` は新テンプレートを参照します。既存の `config.json` が旧テンプレートや存在しない `mdtoday.md` を参照している場合は、次の値に変更してから MDH を再読み込みしてください。

```json
"template": "50_settings\\templates\\DailyTemplate.md"
```

テンプレート相対パスはリポジトリルートから解決されます。テンプレートを見つけられない場合、新規日報は作成されずエラーになります。

## 設定の変更

PowerShell セッションで読み込まれている設定は、初期化時に `config.json` から読み込まれます。設定ファイルを編集した後は、MDH を再度読み込むために新しい PowerShell セッションを開くか、必要に応じて設定とスクリプトを再読み込みしてください。

`paths.daily`、`paths.quicknotes`、`paths.aggregate` の相対パスはMDHルート基準です。これらは表の順に解決され、`{MDH_root}` と先に解決済みのパスを参照できます。変更すると次回以降の読込先や書込先が変わるため、実行前に保存先を確認してください。

## 起動・Concept・Quick Links

| 設定 | 設定内容 |
| --- | --- |
| `startup.open_files` | `mdstart` が設定順に表示を要求するファイル・フォルダーの配列。配布時の順序と参照の種類は[朝の作業](03_daily-workflow.md#朝の作業を始める)を参照 |
| `concepts` | Concept名をキーにしたオブジェクト。各項目に照合用の文字列配列 `keywords` と任意の `category` を指定できる。未登録時は空オブジェクト |
| `tasks` | Quick Linksの既存ページへのリンク設定。項目名が表示名、`rel_dir` の省略時は項目名がディレクトリ名。対応するページが実在する場合に表示 |
| `dotfiles`、`paths.MY_root` | 配布テンプレートにある将来用・旧項目。現行機能の設定には使われない |

`tasks` の `mode` は `aggregate` と `monthly_archive` で `index.md`、`tag_index` で `tag.md` を参照します。探索先はMDHルートの下の「年 / rel_dir / ファイル名」です。この設定からリンク先ページの生成処理が開始されることはありません。Conceptの詳しい照合規則とCategoryの制約は集約設計を参照してください。

例えば、Conceptと起動時の表示を変更する場合は既存JSONの対応箇所に次の値を設定します。

```json
{
  "startup": {
    "open_files": [
      "{quicknotes}\\Overview.md",
      "{quicknotes}\\Ideas.md",
      "{quicknotes}\\Projects\\MDH.md",
      "{todo}",
      "{previous_daily}",
      "{today_daily}"
    ]
  },
  "concepts": {
    "図書整理": {
      "keywords": ["図書", "貸出"],
      "category": "検証"
    }
  }
}
```

予定の外部取得は未実装です。`daily.update_schedule` を有効にしても外部予定は取得されません。

## DBの保存先とPython

`50_settings/config.json` の任意の `db` セクションに `store_dir` と `python` を指定できます。どちらも文字列で、相対パスはMDHルート基準です。既定のストアは `%LOCALAPPDATA%\MarkdownDailyHelper\db\<識別子>` です。識別子はWindowsの大文字・小文字と区切りを正規化したMDHルートの絶対パスから生成する64桁のSHA-256です。

MDHルートを移動すると既定のストアも変わります。日報ルートだけを変更した場合は、`md-db -Status` で現在の設定と索引のルートを確認してください。不一致時の初回構築手順は運用・検証を参照してください。
