# 40_scripts/pwsh_scripts/mdh.ps1

param([switch]$RequireExisting)

# リポジトリルートを取得
$MDHRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot "../..")
)

$MDHConfig = Join-Path $MDHRoot "50_settings\config.json"
$MDHConfigTemplate = Join-Path $MDHRoot "50_settings\config.template.json"

# 初回起動時：テンプレートから設定ファイルを作成
if (-not (Test-Path -LiteralPath $MDHConfig -PathType Leaf)) {
    if ($RequireExisting) { throw "設定ファイルが存在しません: $MDHConfig" }
    if (-not (Test-Path -LiteralPath $MDHConfigTemplate -PathType Leaf)) {
        throw "設定テンプレートが見つかりません: $MDHConfigTemplate"
    }

    $temporary = Join-Path (Split-Path -Parent $MDHConfig) ([guid]::NewGuid().ToString() + '.tmp')
    try {
        [IO.File]::Copy($MDHConfigTemplate, $temporary, $false)
        try {
            [IO.File]::Move($temporary, $MDHConfig)
            Write-Host "設定ファイルを作成しました: $MDHConfig"
        }
        catch [IO.IOException] {
            if (-not [IO.File]::Exists($MDHConfig)) { throw }
            # A concurrent initializer published its configuration first.
        }
    }
    finally { [IO.File]::Delete($temporary) }
}

# 共通関数と初期化処理を読み込む
. (Join-Path $PSScriptRoot "mdh_common.ps1")
. (Join-Path $PSScriptRoot "mdh_init.ps1")

# 初期化実行
Initialize-MDH -MDHRoot $MDHRoot -MDHConfig $MDHConfig -RequireExisting:$RequireExisting

# 起動時だけ使うパス変数を残さない
Remove-Variable MDHConfig, MDHConfigTemplate

# 日報機能を読み込む
. (Join-Path $PSScriptRoot "mdh_daily.ps1")

# todo と Quick Links は独立した機能として読み込む。
. (Join-Path $PSScriptRoot "mdh_todo.ps1")
. (Join-Path $PSScriptRoot "mdh_quicklinks.ps1")
. (Join-Path $PSScriptRoot "mdh_db.ps1")
. (Join-Path $PSScriptRoot "mdh_start.ps1")
. (Join-Path $PSScriptRoot "mdh_aggregate.ps1")
. (Join-Path $PSScriptRoot "mdh_management.ps1")

# その他の機能は、必要に応じて追加する
# . (Join-Path $PSScriptRoot "dotfiles.ps1")
