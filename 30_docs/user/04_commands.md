# MDH コマンド仕様書

## 1. 対象

この文書は、`40_scripts/pwsh_scripts` が定義する利用者向け関数を記録する。`mdh.ps1` をドットソースして PowerShell セッションに読み込む。使用前の設定・テンプレート準備は[取扱説明書](01_getting-started.md)を参照。

## 2. コマンド一覧

MDHを読み込んだセッションではPowerShell標準のヘルプを利用できます。

```powershell
Get-Help daily -Detailed
Get-Help mdstart -Examples
Get-Help md-db -Full
```

通常の結果表示は情報ストリームに出力します。対応するコマンドでは `-Verbose` を付けると、保存先の確認やDB診断コードなどを追加表示します。

| コマンド | 実装状況 | 概要 |
|---|---|---|
| `daily` | 実装済み | 今日または指定日の日報を新規作成・更新して開く |
| `mdtoday` | 実装済み（互換入口） | 日報処理を呼ぶ。`-Open` の有無によらず日報を開く |
| `todo` | 実装済み | todoを更新し、完了タスクを最新日報へ記録して開く |
| `quicklinks` | 実装済み | todoのQuick Links管理領域だけを更新して開く |
| `mdstart` | 実装済み | 当日日報・TODO・DB索引を準備し、設定した対象を開く |
| `mdreverse` | 実装済み | Conceptを指定して日報のTopicを集約 |
| `mdrun` | 実装済み | 登録済みConceptを集約し、全件成功時にindexを更新 |
| `mdversion` | 実装済み | 読み込まれているMDHの製品バージョンを確認 |
| `mdlist` | 実装済み | 有効設定、Concept、Typeを読み取り専用で確認 |
| `mdhelp` | 実装済み | MDH公開コマンドの一覧と標準ヘルプを表示 |
| `md-db` | 実装済み | 検索用DBの状態確認・同期・再構築 |
| `mdsearch` | 実装済み | Dailyの索引とQuickNotesのMarkdownを読み取り専用で検索 |

ここで「実装済み」は現行の読み込みスクリプトに関数が定義されていることを示す。PowerShell セッション内に別ソースから同名コマンドが存在する可能性までは扱わない。

## 3. `daily`

### 概要

対象日の日報を作成または更新し、ファイルを開く。既存ファイルの場合、設定が有効ならナビゲーションと予定の管理領域を更新する。旧形式では安全に範囲を特定できる領域のみ更新する。

### 使用方法

```powershell
daily
daily '2026-10-31'
daily -DateText '2026-10-31'
daily -Date '2026-10-31'
daily -Prev
daily -DateText '2026-10-31' -Prev
```

### 引数・オプション

| 引数 | 型 | 位置 | 既定 | 意味 |
|---|---|---:|---|---|
| `DateText` | string | 0 | 実行日 `yyyy-MM-dd` | 対象日、または `-Prev` 使用時の基準日 |
| `Date` | alias | — | — | `DateText` の別名 |
| `Prev` | switch | 名前付き | false | 基準日より前に存在する最も新しい日報を対象にする |

日付は `yyyy-MM-dd` 形式で、実在する日付でなければならない。`-Prev` の検索対象は基準日を含まず、前の日報がなければ警告して終了する。

### 実行結果・副作用

- 日報がなければテンプレートから作成する。
- 日報があれば設定に応じて本文の一部を更新する。
- 本文に変更があった場合だけ保存する。
- 対象日報の保存後、実在する直近の前後日報のナビゲーションも更新する。`daily.update_links=false` なら既存日報のリンク更新を省略する。隣接日報の読み書きに失敗した場合は日付を報告して停止し、保存済みの日報は保持する。
- 新規日報のナビゲーションはMarkdownリンク一行で生成し、前後日報がなければ行を省略する。既存日報の正常な旧マーカーは、安全に特定できた範囲だけを移行する。
- 対象日・ファイルと、そのファイルの新規作成・更新・変更なしを表示し、VS Code が利用可能なら VS Code、そうでなければ OS の既定アプリで開く。
- 予定の取得元は未実装。新規日報の生成時と予定更新が有効な既存日報の更新時に、取得不能の警告が表示される。

## 4. `mdtoday`

### 概要

旧入口との互換用として日報処理を呼ぶ。内部では `Start-MdhDaily` を呼び、対象日の処理後に日報を開く。

### 使用方法

```powershell
mdtoday
mdtoday '2026-10-31'
mdtoday -DateText '2026-10-31'
mdtoday -Date '2026-10-31'
mdtoday -DateText '2026-10-31' -Open
```

### 引数・オプション

| 引数 | 型 | 位置 | 既定 | 意味 |
|---|---|---:|---|---|
| `DateText` | string | 0 | 実行日 `yyyy-MM-dd` | 対象日 |
| `Date` | alias | — | — | `DateText` の別名 |
| `Open` | switch | 名前付き | false | 受け付けるが、現在の実装では値を参照しない。指定の有無で挙動は変わらない |

`daily` と異なり `-Prev` は宣言されていない。日付形式、作成・更新、保存、オープン時のエラーと副作用は `daily` と同じ。

## 5. `todo`

### 概要

Markdownのタスクリストを更新して開く。ルーティン元ファイルからタスク名だけを読み、todo内の全見出しで同名項目がなければH2の `## ルーティン` に未完了として追加する。全見出しの完了チェックを、今日以前の最新の日報の `# 🤖 自動入力` 配下にある一意な `## done` に記録してから整理する。既存の任意見出し・未完了タスク・手入力は保持する。

### 使用方法

```powershell
todo
```

todoの初期ファイルは `todo.file`（既定 `{quicknotes}\00_TODO.md`）に作成する。ルーティンは `todo.routine_file`（既定 `50_settings\templates\TodoRoutine.md`）から読み込み、Routine側のチェック状態は無視して定義として扱う。最新日報がない、旧形式である、転記先が欠落・重複している、または旧履歴との照合が曖昧な場合、完了チェックはtodoに保持する。処理結果にはTODOのパス、追加したルーティンと日報に新しく転記した件数、または転記を保留した件数を表示する。日報への記録形式、保存競合、ルーティン同期の詳細はtodo・Quick Links仕様を参照。

## 6. `quicklinks`

### 概要

todoファイルのQuick Links管理領域を更新して開く。今日・前日の日報、存在するアーカイブ、`tasks` 設定に対応する実在インデックスへのリンクを生成する。手入力を含む管理マーカー外の本文は変更しない。

### 使用方法

```powershell
quicklinks
quicklinks -DateText '2026-10-31'
```

| 引数 | 型 | 既定 | 意味 |
|---|---|---|---|
| `DateText` | string | 実行日 `yyyy-MM-dd` | 今日のリンクとして扱う日付 |

日付は `daily` と同じ厳密な `yyyy-MM-dd` 形式で検証する。Quick Linksの見出しや管理マーカーが重複・不整合の場合は警告し、更新しない。

## 7. 内部関数について

`Start-MdhDaily`、`Get-MdhDailyPath`、`Update-MdhDailyFile` 等も PowerShell 関数として読み込まれるが、主に日報処理を構成する内部関数である。詳細は日報処理の技術資料を参照する。

## 8. 現在利用できないコマンド

README や設定テンプレートに関連記述があっても、以下のコマンドは現行スクリプトに定義されていない。

予定の外部取得とdotfiles保存・復元は将来用。

## `mdreverse` と `mdrun`

| コマンド | 動作 |
|---|---|
| `mdreverse '図書整理'` | 対象Conceptの全Typeを集約。未登録なら指定名で照合 |
| `mdreverse '図書整理' -Register` | 新規Conceptを設定に保存してから集約 |
| `mdreverse '図書整理' -Type Meeting` | 指定のTypeを絞り込み、Markdownを出力ストリームへ返す |
| `mdreverse '図書整理' -Type Meeting -OutputPath './meeting.md'` | 作業ディレクトリ基準の指定先にexport。Typeの省略時は全Type |
| `mdrun` | 登録済みConceptを処理。全件成功時だけindexを更新 |

`-Register` は `-Type`・`-OutputPath` と併用不可。Topicが0件の場合は既存の集約・exportを保持する。終了コードは `0` が成功、`1` が一部失敗、`2` が引数・設定エラー、`3` がPython環境エラー、`4` が集約全体の失敗。[操作例](03_daily-workflow.md#concept別の日報を集約する)

### Windowsのjunctionを使った集約

Windowsでは、仮想・マップ済みドライブを通常のドライブ文字付きパスで指定できます。集約ルートやその祖先には、Volume GUIDのボリューム直下を指すものを含め、対応するjunctionを使えます。集約ルート内部のjunctionは拒否されます。`mdrun` のindexは解決後の集約ルート直下に書き出されます。

`mdreverse -OutputPath` では、明示したexportファイルの祖先にjunctionを使えます。Daily、QuickNotes、設定されたTODOファイル、設定ファイル、設定テンプレート、集約領域へのexportは別名パス経由でも拒否されます。`-Register` の設定保存ではjunctionを含むリパースポイントを拒否します。

保存には出力ドライブがファイルの作成と置換に対応している必要があります。失敗時は、実行直後の `$LASTEXITCODE` とPowerShellのエラーメッセージで対象パスと理由を確認してください。`mdrun` が一部失敗した場合、成功したConceptの出力は更新されることがあります。indexは保持されます。複数プロセスによる同時集約や複数PCからの同時編集は保証範囲外です。

生成Markdownのリンクは、解決後の出力先を基準に作られます。リンク先が異なるWindowsドライブにある場合は `file:` URIになり、開けるかどうかはMarkdownビューアに依存します。

## `mdstart`

起動時の日付を固定し、Daily → TODO（Quick Linksを含む）→ DB Status → RebuildまたはSync → ファイル表示 → サマリーの順で実行する。前日以前にチェックした未整理タスクも、当日日報の完了履歴に記録されることがある。

```powershell
mdstart
mdstart -NoOpen
mdstart -SkipDb
mdstart -NoOpen -SkipDb -Verbose
```

| オプション | 動作 |
|---|---|
| `-NoOpen` | 自動ファイル表示をすべて省略 |
| `-SkipDb` | Status・Sync・Rebuildをすべて省略 |
| `-Verbose` | 実行する段階の詳細ログを表示 |

Statusが正常でDBが未初期化なら一度だけRebuildする。初期化済みならSyncする。Dailyが失敗した場合はTODOとDBを省略し、TODOの更新・完了記録が失敗した場合はDBを省略する。Statusの失敗・不正応答・破損を検出した場合はDB更新を中止する。Syncの部分成功と表示失敗は警告として集計する。利用可能なファイルの表示とサマリーは、先行する段階で失敗しても続行する。

表示対象は `startup.open_files` の配列に設定する。既定は `{todo}`、`{previous_daily}`、`{today_daily}`。絶対パス、MDHルート基準の相対パス、`{quicknotes}\Projects\MDH.md` のように先頭にフォルダー参照を1個置いたパスを指定できる。不正な指定や存在しない対象は警告してスキップし、前回の日報がない場合は警告なしで省略する。設定の省略、空配列、`null` では表示要求を行わない。VS Code CLIに重複を除いた設定順で `--reuse-window` 付きの要求を送り、サマリーに表示要求件数を示す。[取扱説明書](03_daily-workflow.md#朝の作業を始める)

---

## 9. DB・検索コマンド

| コマンド | 動作 |
|---|---|
| `md-db` / `md-db -Status` | 読取り専用。初期化有無、世代、状態別件数、最終試行日時、最終完全成功日時を返す。 |
| `md-db -Sync` | 既存世代を増分同期する。部分成功・保留でも結果と診断を返す。 |
| `md-db -Sync -ConfirmDeletions <string[]>` | Dailyルート基準の相対パスを個別確認する。例は下記。 |
| `md-db -Rebuild` | 初回構築、または検証済みの新世代へ切替。運用世代で未確定の欠落が1件でもあれば公開を中止する。 |
| `md-db -Rebuild -WhatIf` | 実行予定を表示して終了する。Pythonを起動せずストアも作らない。`-Confirm` も使用できる。 |
| `mdsearch "図書 CSV"` | 日本語部分一致。Unicode空白で語を分け、同一検索グループ内のANDを評価する。LIKEの `%`、`_`、`\` はリテラル。 |

`-Sync`、`-Rebuild`、`-Status` は排他的。削除確認は `-Sync` 専用で、絶対パス、親ディレクトリ参照、未観測のパスは拒否する。確認後も連続2回の正常走査、大量不在ガード、確定直前の再検査が必要。削除対象は派生DBの行のみ。

```powershell
md-db -Sync -ConfirmDeletions @('2026/2026-11/2026-11-20.md')
mdsearch '図書 CSV' -From '2026-11-01' -To '2026-11-30' -IncludeStale
mdsearch '図書 CSV' -FullPath
mdsearch '図書 CSV' -DebugInfo
$response = mdsearch '図書 CSV' -Raw
```

`-From`、`-To` は各境界を含む `yyyy-MM-dd`。期間指定時の日付不明 INVALID は別集計する。既定では CURRENT のみを検索する。`-IncludeStale` で追加される結果は最後の正常スナップショットの位置を返す。結果には Dailyルート基準のパス、見出し、抜粋、行・列番号（1始まり）、原文オフセット（BOMを除く Unicode コードポイント、0始まり・終端排他）が含まれる。0件でも完全性情報を返し、検索・状態確認は同期やDB作成を行わない。

PowerShellは `$LASTEXITCODE` に操作結果を設定する。Python CLIは `contract_version`（1）、`operation`、`exit_code`、`result`、`diagnostics` を含むUTF-8 JSONを標準出力に1件返す。

通常の `mdsearch` は検索元をセクションで分け、グループごとに見出しとパスを1回、その下に一致行を行番号順で表示する。件数はTopic、その他のDailyグループ、QuickNotesのファイル、グループ内の異なる一致行を区別する。原文ハッシュが一致しない場合やSTALEの場合は索引上の行番号と抜粋を表示する。`-List` は通常表示と同じ。`-FullPath` で絶対パスを表示し、外部保存先は既定でも絶対パスを表示する。`-DebugInfo` は構造化応答を情報ストリームに表示する。

```powershell
mdsearch "SQLite index" -Scope Daily
mdsearch "SQLite index" -Scope QuickNotes
mdsearch "SQLite index" -Scope All -From '2026-11-01'
$response = mdsearch "SQLite index" -Scope All -Raw
```

`-Scope` の既定は `Daily`。Dailyは索引上の同一検索グループ、QuickNotesは同一ファイルを単位として、空白区切りの語をANDで検索する。ASCII英字のみ大文字・小文字を同一視する。`QuickNotes` は仮想ドライブを含む `paths.quicknotes` 以下のMarkdownを読み取り専用で検索し、Daily DBの初期化や同期は不要。Cloud Filesで管理される項目も読み取り対象とする。編集内容は次回の検索に反映する。配下のjunction、シンボリックリンク、未対応のリパースポイントは追跡せず、除外を診断に記録する。

QuickNotes内のハードリンクは、リンク数にかかわらず通常のMarkdownとして検索する。ルート外のファイル名と同じファイル実体を共有する場合も、その内容が検索対象になる。検索ルートはファイルの探索範囲を定めるもので、アクセス権限を分離するセキュリティ境界ではない。集約出力では引き続きハードリンクを拒否する。

`-From`、`-To`、`-IncludeStale` はDailyの条件で、`QuickNotes` 単独では指定できない。`All` はDaily、QuickNotesの順に表示し、期間指定はDailyに適用する。

Dailyの `-Raw` は従来の構造化応答を返す。QuickNotesとAllの `-Raw` は `search_contract_version: 1` の応答を1件返し、実行した検索元の状態と結果を `sources` に含める。Allの `sources.daily.response` は従来のDaily応答そのもの。状態は `success`、`partial`、`error` で、`$LASTEXITCODE` は順に0、1、4。検索要求が不正な場合は実行前に終了コード2を返す。個別ファイルを読めずに続行した場合はQuickNotes結果の `incomplete` と `diagnostics` を確認する。エラー時は構造化応答を成功ストリームに送ってからエラーストリームに通知する。`-ErrorAction Stop` で中断しても応答を保持したい場合は、パイプラインで受け取った応答を処理する。

索引と原文のSHA-256が一致する場合は一致行を表示し、対応する端末では一致語を色で強調する。SHA不一致・原文不在・読取り不能・STALEの場合は索引の抜粋を使い、行番号を `索引 L24` のように表示する。`-Raw` の位置は常に `snapshot_hash` が識別する索引元の位置。0件の場合は日本語の案内を表示し、不完全の可能性がある場合は除外件数と最終完全成功日時を表示する。

`hits` は検索グループ単位。`matches` は検索語・スパン・一致行ごとの先頭位置で、同じ行での全出現位置や出現回数は返さない。通常表示の総件数は検索グループ内の一致行数を合計した値。

| コード | 意味 |
|---|---|
| 0 | 成功。検索0件、不完全性を伴う検索、未初期化の状態確認を含む。 |
| 1 | 同期の部分成功・保留。結果と診断を保持し、警告を出す。 |
| 2 | 引数・設定エラー |
| 3 | Python環境・依存関係エラー |
| 4 | DB状態異常・日報ルート不一致・未初期化の検索または同期・同期全体の中止 |
| 5 | writer lockの競合 |
| 6 | 再構築の検証・公開失敗 |

`md-db -Status` は索引の日報ルートを `daily_root`、現在の設定を `configured_daily_root`、照合結果を `daily_root_matches` で返す。不一致時はStatusと検索が警告し、終了コード4を返す。検索結果の表示は省略する。

導入は[取扱説明書](01_getting-started.md)、異常時は運用・検証を参照。

## 管理コマンド

- `mdversion` は読み込み元の製品ルートにある `VERSION` を表示します。`-Raw` は `product` と `version` を持つPowerShellオブジェクト1件を返します。
- `mdlist [config|concept|type]` の既定は `config` です。`config` はセッションで解決済みのパス、日報・TODO・DB・Python設定、Startupの指定順を表示します。Startupの動的プレースホルダーは設定値のまま表示します。Conceptは実行時に設定ファイルから読み直します。
- `mdlist concept` は登録名、Category、キーワード、登録件数を表示します。`-Count` はconcept専用で、集約と同じ照合規則でDaily Markdownを一度走査します。集計失敗時は定義を保持し、`topic_count` を `null` とします。
- `mdlist type` はDaily Markdownの集約対象Topicを既存のType正規化規則でまとめます。代表名には集約順で最初の表記を用います。未分類は `name`・`key` ともに `null` です。合計件数はSQLiteの全Topic件数と異なる場合があります。
- `mdlist -Raw` は `contract_version`、`target`、`status`、`result`、`diagnostics` を持つPowerShellオブジェクト1件を返します。取得結果は `success`、`partial`、`error` のいずれかです。不正な引数は引数エラーになります。
- `mdhelp` は全公開コマンドと概要を表示します。`mdhelp mdsearch -Examples` のように個別ヘルプを参照できます。`-Detailed`・`-Examples`・`-Full` はコマンド名とともに1つだけ指定します。
