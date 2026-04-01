#!/bin/bash
set -e

if [[ -n "$SOUND_DISABLE_MPD" ]]; then
  echo "MPD is disabled, exiting..."
  exit 0
fi


SMB_HOST="${SMB_HOST:-//10.0.10.7/Syno-music}"
SMB_USER="${SMB_USER:-music}"
SMB_PASS="${SMB_PASS:-}"
MOUNT_POINT="/music"
USB_MOUNT="/mnt/usb"
USB_SRC_DIR="Music"
USB_DST="/music/usb"

echo "--- MPD Container Starting ---"

mkdir -p "$MOUNT_POINT"
mkdir -p "$USB_MOUNT"
mkdir -p "$USB_DST"
mkdir -p /var/lib/mpd
mkdir -p /var/log/mpd
mkdir -p /run/mpd

if [ -f /var/lib/mpd/database ] && ! mpd --check-config /etc/mpd.conf 2>/dev/null; then
    rm -f /var/lib/mpd/database /var/lib/mpd/state
fi
if [ -f /var/lib/mpd/database ] && [ ! -s /var/lib/mpd/database ]; then
    rm -f /var/lib/mpd/database
fi

# SMBマウント
mount_smb() {
    echo "Mounting SMB: $SMB_HOST -> $MOUNT_POINT"
    mount -t cifs "$SMB_HOST" "$MOUNT_POINT" \
        -o "username=$SMB_USER,password=$SMB_PASS,uid=0,gid=0,vers=3.0,iocharset=utf8" \
        && echo "SMB mount successful" \
        || { echo "SMB mount failed, retrying in 10s..."; return 1; }
}

until mount_smb; do
    sleep 10
done

# USB同期関数
sync_usb() {
    local dev="$1"
    echo "USB detected: $dev"
    mount -t exfat "$dev" "$USB_MOUNT" -o uid=0,gid=0 2>/dev/null \
        || mount "$dev" "$USB_MOUNT" 2>/dev/null \
        || { echo "USB mount failed"; return 1; }
    echo "USB mounted at $USB_MOUNT"

    if [ -d "$USB_MOUNT/$USB_SRC_DIR" ]; then
        echo "Syncing $USB_MOUNT/$USB_SRC_DIR -> $USB_DST ..."
        rsync -av --delete "$USB_MOUNT/$USB_SRC_DIR/" "$USB_DST/"
        echo "Sync complete"
    else
        echo "Directory $USB_SRC_DIR not found on USB"
    fi

    umount "$USB_MOUNT" && echo "USB unmounted safely"

    # MPD ライブラリ更新
    mpc -p 6600 update --wait
    mpc -p 6600 clear
    mpc -p 6600 listall | mpc -p 6600 add
    mpc -p 6600 repeat on
    mpc -p 6600 random off
    mpc -p 6600 play 1
    echo "Playlist updated. Total: $(mpc -p 6600 playlist | wc -l) tracks"
}

# USB監視バックグラウンドループ
usb_watch() {
    echo "Watching for USB devices..."
    while true; do
        # /dev/sd* デバイスを監視
        inotifywait -e create /dev 2>/dev/null | while read -r dir event dev; do
            case "$dev" in
                sd[a-z]1|sd[a-z])
                    sleep 2  # デバイス安定待ち
                    sync_usb "/dev/$dev"
                    ;;
            esac
        done
        sleep 5
    done
}

# MPD起動
echo "Starting MPD..."
mpd /etc/mpd.conf
sleep 5

# DB更新・全曲追加・ループ再生
echo "Updating music database..."
mpc -p 6600 update --wait

echo "Building playlist..."
mpc -p 6600 clear
mpc -p 6600 listall | mpc -p 6600 add
TOTAL=$(mpc -p 6600 playlist | wc -l)
echo "Total tracks: $TOTAL"

mpc -p 6600 repeat on
mpc -p 6600 random off
mpc -p 6600 play
echo "Playback started."

# USB監視をバックグラウンドで起動
usb_watch &

# SMBファイル変更監視
echo "Watching for file changes..."
inotifywait -m -r \
    -e create -e delete -e moved_to -e moved_from -e close_write \
    "$MOUNT_POINT" 2>/dev/null |
while read -r directory event filename; do
    case "${filename,,}" in
        *.m4a|*.flac|*.mp3)
            echo "File changed: $event $directory$filename"
            sleep 3
            mpc -p 6600 update --wait
            mpc -p 6600 clear
            mpc -p 6600 listall | mpc -p 6600 add
            mpc -p 6600 play 1
            echo "Playlist updated. Total: $(mpc -p 6600 playlist | wc -l) tracks"
            ;;
    esac
done
