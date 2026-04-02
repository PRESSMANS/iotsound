#!/bin/bash

if [[ -n "$SOUND_DISABLE_MPD" ]]; then
  echo "MPD is disabled, exiting..."
  exit 0
fi

USB_MOUNT="/mnt/usb"
USB_SRC_DIR="Music"
USB_DST="/music/usb"
SYNCED_DEV=""

echo "--- MPD Container Starting ---"

mkdir -p "$USB_MOUNT" "$USB_DST" /var/lib/mpd /var/log/mpd /run/mpd

[ -f /var/lib/mpd/database ] && [ ! -s /var/lib/mpd/database ] && rm -f /var/lib/mpd/database

sync_usb() {
    local dev="$1"

    # パーティションデバイスのみ（sda1 など数字で終わるもの）
    [[ "$dev" =~ [0-9]$ ]] || { echo "Skipping non-partition: $dev"; return 1; }

    # 同じデバイスは再同期しない
    [ "$dev" = "$SYNCED_DEV" ] && { echo "Already synced: $dev"; return 0; }

    echo "USB detected: $dev"
    mountpoint -q "$USB_MOUNT" && umount "$USB_MOUNT" 2>/dev/null || true

    mount -t exfat "$dev" "$USB_MOUNT" -o uid=0,gid=0 2>/dev/null \
        || mount "$dev" "$USB_MOUNT" 2>/dev/null \
        || { echo "USB mount failed for $dev"; return 1; }
    echo "USB mounted"

    if [ -d "$USB_MOUNT/$USB_SRC_DIR" ]; then
        echo "Syncing..."
        rsync -a --delete \
            --exclude='._*' --exclude='.DS_Store' \
            --exclude='.Spotlight-V100' --exclude='.Trashes' \
            "$USB_MOUNT/$USB_SRC_DIR/" "$USB_DST/" || true
        echo "Sync complete"
    fi

    umount "$USB_MOUNT" 2>/dev/null || true
    SYNCED_DEV="$dev"

    # 再生中でなければプレイリスト更新・再生開始
    STATUS=$(mpc -p 6600 status 2>/dev/null | grep -E '^\[' | awk '{print $1}')
    if [ "$STATUS" != "[playing]" ]; then
        mpc -p 6600 update --wait || true
        mpc -p 6600 clear || true
        mpc -p 6600 listall | mpc -p 6600 add || true
        TOTAL=$(mpc -p 6600 playlist | wc -l)
        mpc -p 6600 repeat on || true
        mpc -p 6600 random off || true
        [ "$TOTAL" -gt 0 ] && mpc -p 6600 play || true
        echo "Playback started. Total: $TOTAL tracks"
    else
        # 再生中はライブラリだけ更新
        mpc -p 6600 update || true
        echo "Library updated while playing"
    fi
}

usb_watch() {
    echo "Watching for USB devices..."
    while true; do
        for dev in /dev/sd?1; do
            [ -b "$dev" ] && sync_usb "$dev" && break
        done
        # デバイスが消えたらリセット
        if [ -n "$SYNCED_DEV" ] && [ ! -b "$SYNCED_DEV" ]; then
            echo "USB removed: $SYNCED_DEV"
            SYNCED_DEV=""
        fi
        sleep 10
    done
}

# MPD 起動
echo "Starting MPD..."
mpd /etc/mpd.conf || true
sleep 5

# 起動時 USB チェック
for dev in /dev/sda1 /dev/sdb1; do
    [ -b "$dev" ] && { sync_usb "$dev"; break; }
done

# プレイリスト構築・再生
echo "Building playlist..."
mpc -p 6600 update --wait || true
mpc -p 6600 clear || true
mpc -p 6600 listall | mpc -p 6600 add || true
TOTAL=$(mpc -p 6600 playlist | wc -l)
echo "Total tracks: $TOTAL"
mpc -p 6600 repeat on || true
mpc -p 6600 random off || true
[ "$TOTAL" -gt 0 ] && mpc -p 6600 play || true
echo "Playback started."

usb_watch &
wait
