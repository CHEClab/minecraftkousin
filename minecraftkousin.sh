#!/bin/bash

# ==============================================================================
# PaperMC Automatic Updater & Discord Notifier
# ==============================================================================
# 【概要】
# PaperMCサーバーを全自動で最新のMinecraftバージョン・最新ビルドに追従させ、
# 更新完了時にDiscordへサイレント通知（@silent）を送信するスクリプトです。
#
# 【特徴】
# - 公式APIから自動で最新バージョンを取得（メジャーアップデートにも全自動で対応）
# - 本番環境を汚さないよう、専用の作業用フォルダで必須ファイルを展開
# - 展開前のクリーンアップ処理により、古いライブラリの干渉と容量圧迫を防止
# - jarファイルの破損検知（10MB未満を弾く）、APIダウン時のフェイルセーフ搭載
# - systemdと連携し、ファイルロックを回避した安全なエンジンのクリーンインストール
#
# 【必要なパッケージ】
# sudo apt update && sudo apt install jq curl wget -y
#
# 【使い方】
# 1. 以下の「設定エリア」のパスやサービス名を、ご自身の環境に合わせて変更してください。
# 2. スクリプトに実行権限を付与します。
#    chmod +x minecraftkousin.sh
# 3. root権限のcronに登録して自動化します（systemctlを操作するためroot権限が必要です）。
#    sudo crontab -e
#
#    [cron設定例] 毎日午前5時45分に実行し、ログを作業フォルダに保存する
#    45 5 * * * /path/to/minecraftkousin.sh >> /path/to/minecraftsagyou/update.log 2>&1
#
# 【手動での強制再インストールについて】
# エンジンが破損した場合は、記録ファイルを消去してスクリプトを実行することで復旧可能です。
# sudo rm /path/to/minecraft/server.jar
# sudo rm /path/to/minecraft/.mc_version
# sudo /path/to/minecraftkousin.sh
# ==============================================================================

# ==========================================
# 設定エリア (環境に合わせて変更してください)
# ==========================================
# マインクラフトの本番サーバーがあるディレクトリ
MINECRAFT_DIR="/home/user/minecraft"

# アップデート用の一時作業ディレクトリ
WORK_DIR="/home/user/minecraftsagyou"

# 停止・起動するsystemdのサービス名 (複数ある場合は下の行を追加/変更してください)
SERVICE_MC="minecraft-playit.service"
SERVICE_TUNNEL="playit.service"

# ファイルの所有権を持たせるユーザー名とグループ名 (例: ubuntu:ubuntu)
CHOWN_USER="user:user"

# DiscordのWebhook URL (通知が不要な場合は空欄 "" にしてください)
# ⚠️警告: 公開リポジトリにPushする際は、絶対にここに本物のURLを書かないでください！
WEBHOOK_URL="YOUR_DISCORD_WEBHOOK_URL_HERE"

# ==========================================
# 1. APIから最新バージョンとビルドを取得
# ==========================================
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

latest_mc_version=$(curl -s "https://api.papermc.io/v2/projects/paper" | jq -r '.versions[-1]')

if [ -z "$latest_mc_version" ] || [ "$latest_mc_version" == "null" ]; then
    echo "$(date): エラー - PaperMC APIからマイクラバージョンを取得できませんでした。"
    exit 1
fi

latest_paper_version=$(curl -s "https://api.papermc.io/v2/projects/paper/versions/${latest_mc_version}" | jq -r '.builds[-1]')

if [ -z "$latest_paper_version" ] || [ "$latest_paper_version" == "null" ]; then
    echo "$(date): エラー - PaperMC APIからビルド番号を取得できませんでした。"
    exit 1
fi

# ==========================================
# 2. アップデート判定
# ==========================================
DO_UPDATE=false
current_paper_version="不明"

if [ ! -f "$MINECRAFT_DIR/server.jar" ]; then
    echo "$(date): server.jarが見つかりません。新規インストールとして実行します。"
    current_paper_version="なし"
    DO_UPDATE=true
else
    if [ -f "$MINECRAFT_DIR/.mc_version" ]; then
        current_paper_version=$(cat "$MINECRAFT_DIR/.mc_version")
        if [ "$current_paper_version" != "$latest_paper_version" ]; then
            DO_UPDATE=true
        else
            echo "$(date): Paperは既に最新版です (MC: $latest_mc_version / ビルド: $latest_paper_version)"
            exit 0
        fi
    else
        DO_UPDATE=true
    fi
fi

# ==========================================
# 3. 更新・展開・再起動処理
# ==========================================
if [ "$DO_UPDATE" = true ]; then
    echo "$(date): アップデートを開始します (MC: $latest_mc_version - ビルド $latest_paper_version)"

    echo "作業用フォルダの古いデータをクリーンアップ中..."
    rm -rf "$WORK_DIR"/*

    DOWNLOAD_URL="https://api.papermc.io/v2/projects/paper/versions/${latest_mc_version}/builds/${latest_paper_version}/downloads/paper-${latest_mc_version}-${latest_paper_version}.jar"
    wget -q -O paper.jar "$DOWNLOAD_URL"
    
    FILE_SIZE=$(stat -c%s "paper.jar" 2>/dev/null)
    if [ -z "$FILE_SIZE" ] || [ "$FILE_SIZE" -lt 10000000 ]; then
         echo "$(date): エラー - ダウンロードファイルが異常です。更新を中止します。"
         exit 1
    fi

    echo "作業用フォルダで展開処理を実行中..."
    java -jar paper.jar

    systemctl stop "$SERVICE_MC"
    systemctl stop "$SERVICE_TUNNEL"

    rm -f "$MINECRAFT_DIR/server.jar"
    cp paper.jar "$MINECRAFT_DIR/server.jar"

    chmod +x "$MINECRAFT_DIR/server.jar"
    chown $CHOWN_USER "$MINECRAFT_DIR/server.jar"

    echo "$latest_paper_version" > "$MINECRAFT_DIR/.mc_version"
    chown $CHOWN_USER "$MINECRAFT_DIR/.mc_version"

    systemctl start "$SERVICE_TUNNEL"
    systemctl start "$SERVICE_MC"

    echo "$(date): 更新と再起動が完了しました。"

    if [ "$WEBHOOK_URL" != "" ] && [ "$WEBHOOK_URL" != "YOUR_DISCORD_WEBHOOK_URL_HERE" ]; then
        MESSAGE="🆙 **Minecraft(Paper) サーバー更新完了**\nバージョン: \`$latest_mc_version\`\nビルド: \`$current_paper_version\` ➔ \`$latest_paper_version\`\n自動アップデートと再起動が正常に完了しました！"
        
        # flags: 4096 でサイレント通知（通知音なし）
        curl -s -H "Content-Type: application/json" -X POST -d "{\"content\": \"$MESSAGE\", \"flags\": 4096}" "$WEBHOOK_URL"
    fi
fi