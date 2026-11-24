# 日報・TODO・検索の使い方

## 日報の作成・更新

### 朝の作業を始める

```powershell
mdstart
```

当日日報を作成・更新し、TODOとQuick Linksを更新してから検索用DBを準備します。DBが正常に未初期化と判定された初回は全件構築し、以降は差分同期します。完了タスクは、前日以前の未整理分も当日日報に記録される場合があります。

最後に `config.json` の `startup.open_files` を設定順に開きます。配布テンプレートには次の順序で設定されています。

1. `{todo}` — `todo.file` で指定したTODOファイル
2. `{previous_daily}` — 当日より前の最新日報。該当する日報がなければ省略
3. `{today_daily}` — 当日日報

絶対パスとMDHルート基準の相対パスを指定できます。`{MDH_root}`、`{quicknotes}`、`{daily}`、`{aggregate}` はフォルダー参照です。パスの先頭に1個だけ指定し、単独ならフォルダーを、`{quicknotes}\Projects\MDH.md` のように相対パスを続けると指定したファイルやサブフォルダーを開きます。QuickNotesの保存先は `paths.quicknotes` で指定し、その中の構成は自由です。上の3つのファイル参照は単独で使います。

フォルダーを開くと、再利用されるウィンドウの作業フォルダーが切り替わる場合があります。不正な参照や存在しない対象は警告してスキップします。ワイルドカードは展開されません。[JSONでの設定例](02_configuration.md#起動conceptquick-links)

同じパスへの要求は一度だけ送ります。VS Code CLIの `--reuse-window` は最後にアクティブだったウィンドウを再利用します。複数ウィンドウがある場合、実行元と異なるウィンドウが選ばれることがあります。`Open` はCLIへの起動要求件数です。CLIが失敗した場合や対象が見つからない場合は警告を表示します。[VS Code CLI](https://code.visualstudio.com/docs/configure/command-line)

表示を省略するには `mdstart -NoOpen`、DBを省略するには `mdstart -SkipDb` を使います。両方の指定や、詳細ログ用の `-Verbose` を併用できます。

### 今日の日報

対象日報を作成・更新すると、実在する直近の前後日報のナビゲーションも更新します。既存日報のリンク更新を省略するには `daily.update_links` を `false` にします。

```powershell
daily
```

日報がなければテンプレートから作成し、存在すれば設定に従って対象部分を更新します。処理後にファイルを開きます。

### 日付を指定

```powershell
daily -DateText '2026-10-31'
daily '2026-10-31'
```

日付形式は `yyyy-MM-dd` です。存在しない日付や別形式はエラーです。

### 直近の過去日報

```powershell
daily -Prev
daily -DateText '2026-10-31' -Prev
```

基準日より前に保存されている最も新しい日報を開きます。前の日報がない場合は警告して終了します。

### 互換コマンド

```powershell
mdtoday
mdtoday -DateText '2026-10-31' -Open
```

`mdtoday` は互換入口です。`-Open` は受け付けますが、現在は常にファイルを開き、スイッチの指定で動作は変わりません。

## 日報の保存先と編集

既定の配置:

```text
01_Daily/
  yyyy/
    yyyy-MM/
      yyyy-MM-dd.md
```

日報は通常の Markdown ファイルです。利用者はエディターで直接編集できます。既存日報を `daily` で再処理すると、更新フラグに従ってナビゲーションと予定の自動管理領域を更新します。ヘッダーのナビゲーションはMarkdownリンク一行で、正常な旧マーカーはその日報のリンク更新時に移行します。新規日報では `## 📅 今日の予定` の `MDH:APPOINTMENTS:END` より後に予定を手入力してください。作業の記録は `# ✅ やったこと` に記入します。

予定の外部取得機能は未実装です。現在のコマンドで実際の予定が自動取得されることはありません。詳細な更新境界は日報処理の技術資料を参照。

## todoとQuick Links

### タスクを編集する

```powershell
todo
```

初回実行時、既定で `00_QuickNotes\00_TODO.md` を作成して開きます。基本の見出しはH2の `## ルーティン` と `## やること` です。見出しやチェックボックスはMarkdownとして自由に編集できます。ルーティンの元項目は `50_settings\templates\TodoRoutine.md` に記載してください。Routineファイル内のチェック状態は無視され、todoに追加される項目は未完了になります。同じタスク名がtodo内にあれば、見出しにかかわらず新たに追加しません。

`todo` は今日以前で最新の日報の `# 🤖 自動入力` 配下にある `## done` に、完了項目を実行日と見出し付きで記録してから整理します。最新日報が旧形式、転記先が欠落・重複、または旧履歴との照合が曖昧な場合は、警告して完了チェックを残します。`# ✅ やったこと` や旧履歴はそのまま保持します。ルーティンは当日記録済みなら再追加せず、翌日以降に未完了として再登場します。

### Quick Linksを更新する

```powershell
quicklinks
```

Quick Linksだけを独立して更新できます。`todo` 実行時にも専用関数が呼ばれます。管理マーカー外に手入力したリンクやタスクは変更されません。

旧設定 `todo.routines` にルーティンが残っている場合は、項目を `todo.routine_file` のMarkdownファイルへ移してください。

詳しい更新範囲と失敗時の保護はtodo・Quick Links仕様を参照してください。

## 日報のDB検索を使う

Python環境は[導入](01_getting-started.md#python環境を用意する)を参照してください。

### 初回構築と日常操作

```powershell
. .\40_scripts\pwsh_scripts\mdh.ps1
md-db -Status
md-db -Rebuild -WhatIf
md-db -Rebuild
md-db -Sync
mdsearch '図書 CSV'
$search = mdsearch '図書 CSV' -Raw
$search.result.hits
$search.result.incomplete
```

初回構築には `-Rebuild` を使います。日報を編集した後は `-Sync` で反映します。通常検索は CURRENT が対象です。検索0件の場合も、`result.incomplete`、`result.excluded`、`result.last_full_success` を確認してください。明示的な `-IncludeStale` で参照する位置は最後の正常スナップショットの位置です。検索・状態確認は暗黙に同期しません。

引数の詳細は[コマンド仕様](04_commands.md)、失敗時の手順は運用・検証を参照してください。

## Concept別の日報を集約する

日報の `# ✅ やったこと` 配下に、例えば `## [Meeting] 図書整理の打合せ` と書き、その下に本文を記録します。続く例では、Concept名がTopicの見出しに含まれるため集約対象になります。Typeを指定したプレビューでは、見出し先頭の `[Meeting]` で絞り込みます。

```powershell
mdreverse '図書整理' -Register
mdreverse '図書整理' -Type Meeting
mdreverse '図書整理' -OutputPath './report.md'
mdrun
```

`-Register` で追加されたConceptには、`50_settings/config.json` の `concepts` 配下で `keywords` と `category` を指定できます。通常の `mdreverse` は既定の `10_Aggregate` に出力し、`mdrun` は全Conceptの処理に成功した場合だけ `index.md` を更新します。Type表示のみの場合は、作業ディレクトリを基準に相対リンクを作ります。

`config.json` の編集中は `mdreverse -Register` を実行しないでください。編集内容を保存し、編集を終えてから実行してください。

集約にはDBコマンドと同じPython環境・Markdownライブラリを使います。Dailyを直接読むため、索引の作成や同期は不要です。Dailyの解析が失敗したら、表示された相対パスと解析理由を確認してください。集約の基本設計
