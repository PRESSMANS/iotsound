#!/bin/bash

if [[ -n "$SOUND_DISABLE_MPD" ]]; then
  echo "MPD is disabled, exiting..."
  exit 0
fi

USB_MOUNT="/mnt/usb"
USB_SRC_DIR="Music"
USB_DST="/music/usb"

echo "--- MPD Container Starting ---"

mkdir -p "$USB_MOUNT"
mkdir -p "$USB_DST"
mkdir -p /var/lib/mpd
mkdir -p /var/log/mpd
mkdir -p /run/mpd

if [ -f /var/lib/mpd/database ] && [ ! -s /var/lib/mpd/database ]; then
    rm -f /var/lib/mpd/database
fi

sync_usb() {
    local dev="$1"
    echo "USB detected: $dev"

    # パーティション付きデバイスのみ処理（sda1, sdb1 など）
    if [[ "$dev" != *[0-9] ]]; then
        echo "Skipping non-partition device: $dev"
        return 1
    fi

    # 既にマウント済みなら何もしない
    if mountpoint -q "$USB_MOUNT" 2>/dev/null; then
        echo "USB already mounted, skipping"
        return 0
    fi

    mount -t exfat "$dev" "$USB_MOUNT" -o uid=0,gid=0 2>/dev/null \
        || mount "$dev" "$USB_MOUNT" 2>/dev/null \
        || { echo "USB mount failed for $dev"; return 1; }
    echo "USB mounted at $USB_MOUNT"

    if [ -d "$USB_MOUNT/$USB_SRC_DIR" ]; then
        echo "Syncing $USB_MOUNT/$USB_SRC_DIR -> $USB_DST ..."
        rsync -av --delete \
            --exclude='._*' \
            --exclude='.DS_Store' \
            --exclude='.Spotlight-V100' \
            --exclude='.Trashes' \
            "$USB_MOUNT/$USB_SRC_DIR/" "$USB_DST/" || true
        echo "Sync complete"
    else
        echo "Directory $USB_SRC_DIR not found on USB"
    fi

    umount "$USB_MOUNT" 2>/dev/null && echo "USB unmounted safely" || true

    sleep 2
    mpc -p 6600 update --wait || true
    mpc -p 6600 clear || true
    mpc -p 6600 listall | mpc -p 6600 add || true
    TOTAL=$(mpc -p 6600 playlist | wc -l)
    mpc -p 6600 repeat on || true
    mpc -p 6600 random off || true
    [ "$TOTAL" -gt 0 ] && mpc -p 6600 play 1 || true
    echo "Playlist updated. Total: $TOTAL tracks"
}

usb_watch() {
    echo "Watching for USB devices..."
    local last_dev=""
    while true; do
        # sda1, sdb1 などパーティションのみ対象
        for dev in /dev/sd?1; do
            if [ -b "$dev" ] && [ "$dev" != "$last_dev" ]; then
                sleep 2
                sync_usb "$dev" && last_dev="$dev"
                break
            fi
        done
        # デバイスが消えたらリセット
        if [ -n "$last_dev" ] && [ ! -b "$last_dev" ]; then
            echo "USB removed: $last_dev"
            last_dev=""
        fi
        sleep 10
    done
}

# MPD 起動
echo "Starting MPD..."
mpd /etc/mpd.conf || true
sleep 5

# 起動時に既存の USB デバイスをチェック
for dev in /dev/sda1 /dev/sdb1; do
    if [ -b "$dev" ]; then
        echo "USB device found at boot: $dev"
        sync_usb "$dev"
        break
    fi
done

# DB 更新・プレイリスト構築
echo "Updating music database..."
mpc -p 6600 update --wait || true

echo "Building playlist..."
mpc -p 6600 clear || true
mpc -p 6600 listall | mpc -p 6600 add || true
TOTAL=$(mpc -p 6600 playlist | wc -l)
echo "Total tracks: $TOTAL"

mpc -p 6600 repeat on || true
mpc -p 6600 random off || true
[ "$TOTAL" -gt 0 ] && mpc -p 6600 play || true
echo "Playback started."

# USB 監視をバックグラウンドで
usb_watch &

# メインプロセスを維持
wait
