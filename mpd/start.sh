#!/bin/bash
set -e

SMB_HOST="${SMB_HOST:-//10.0.10.7/music}"
SMB_USER="${SMB_USER:-music}"
SMB_PASS="${SMB_PASS:-}"
MOUNT_POINT="/music"

echo "--- MPD Container Starting ---"

# 必要なディレクトリを作成
mkdir -p "$MOUNT_POINT"
mkdir -p /var/lib/mpd /var/log/mpd /run/mpd

# SMBマウント（リトライあり）
mount_smb() {
    echo "Mounting SMB: $SMB_HOST -> $MOUNT_POINT"
    mount -t cifs "$SMB_HOST" "$MOUNT_POINT" \
        -o "username=$SMB_USER,password=$SMB_PASS,uid=0,gid=0,vers=3.0,iocharset=utf8" \
        && echo "SMB mount successful" \
        || { echo "SMB mount failed, retrying in 10s..."; return 1; }
}

# マウントが成功するまでリトライ
until mount_smb; do
    sleep 10
done

# MPD起動
echo "Starting MPD..."
mpd /etc/mpd.conf
sleep 5

# DB更新・全曲追加・ループ再生開始
echo "Updating music database..."
mpc -p 6600 update --wait

echo "Building playlist..."
mpc -p 6600 clear
mpc -p 6600 listall | mpc -p 6600 add
TOTAL=$(mpc -p 6600 playlist | wc -l)
echo "Total tracks: $TOTAL"

# リピート・ランダムOFF（順番通り再生）でループ
mpc -p 6600 repeat on
mpc -p 6600 random off
mpc -p 6600 play
echo "Playback started."

# ファイル変更を監視して自動更新
echo "Watching for file changes..."
inotifywait -m -r \
    -e create -e delete -e moved_to -e moved_from -e close_write \
    "$MOUNT_POINT" 2>/dev/null |
while read -r directory event filename; do
    # m4a/flac/mp3のみ対象
    case "${filename,,}" in
        *.m4a|*.flac|*.mp3)
            echo "File changed: $event $directory$filename"
            sleep 3  # 連続イベントをまとめる
            echo "Updating database..."
            mpc -p 6600 update --wait
            mpc -p 6600 clear
            mpc -p 6600 listall | mpc -p 6600 add
            CURRENT_POS=$(mpc -p 6600 | grep -oP '#\K[0-9]+' | head -1 || echo "1")
            mpc -p 6600 play "$CURRENT_POS"
            echo "Playlist updated. Total: $(mpc -p 6600 playlist | wc -l) tracks"
            ;;
    esac
done