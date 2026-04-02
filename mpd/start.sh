#!/bin/bash

if [[ -n "$SOUND_DISABLE_MPD" ]]; then
  echo "MPD is disabled, exiting..."
  exit 0
fi

USB_MOUNT="/mnt/usb"
USB_SRC_DIR="Music"
USB_DST="/music/usb"
SYNCED_DEV=""
SYNCED_COUNT=0

echo "--- MPD Container Starting ---"

mkdir -p "$USB_MOUNT" "$USB_DST" /var/lib/mpd /var/log/mpd /run/mpd

[ -f /var/lib/mpd/database ] && [ ! -s /var/lib/mpd/database ] && rm -f /var/lib/mpd/database

sync_usb() {
    local dev="$1"

    [[ "$dev" =~ [0-9]$ ]] || { echo "Skipping non-partition: $dev"; return 1; }

    mountpoint -q "$USB_MOUNT" && umount "$USB_MOUNT" 2>/dev/null || true

    mount -t exfat "$dev" "$USB_MOUNT" -o uid=0,gid=0 2>/dev/null \
        || mount "$dev" "$USB_MOUNT" 2>/dev/null \
        || { echo "USB mount failed for $dev"; return 1; }

    # ファイル数をチェック
    local current_count=0
    if [ -d "$USB_MOUNT/$USB_SRC_DIR" ]; then
        current_count=$(find "$USB_MOUNT/$USB_SRC_DIR" -type f \( -name "*.m4a" -o -name "*.mp3" -o -name "*.flac" \) | wc -l)
    fi

    # 同じデバイスかつファイル数も同じなら再同期しない
    if [ "$dev" = "$SYNCED_DEV" ] && [ "$current_count" -eq "$SYNCED_COUNT" ]; then
        echo "Already synced: $dev ($current_count files)"
        umount "$USB_MOUNT" 2>/dev/null || true
        return 0
    fi

    echo "USB detected: $dev (files: $current_count, prev: $SYNCED_COUNT)"

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
    SYNCED_COUNT="$current_count"

    # 再生中でなければプレイリスト更新・再生開始
    STATUS=$(mpc -p 6600 status 2>/dev/null | grep -E '^\[' | awk '{print $1}')
    if [ "$STATUS" != "[playing]" ]; then
        mpc -p 6600 update --wait || true
        mpc -p 6600 clear || true
        mpc -p 6600 listall | mpc -p 6600 add || true
        TOTAL=$(mpc -p 6600 playlist | wc -l)
        mpc -p 6600 repeat on || true
        mpc -p 6600 random on || true
        [ "$TOTAL" -gt 0 ] && mpc -p 6600 play || true
        echo "Playback started. Total: $TOTAL tracks"
    else
        mpc -p 6600 update || true
        echo "Library updated while playing. Total files: $current_count"
    fi
}

usb_watch() {
    echo "Watching for USB devices..."
    while true; do
        for dev in /dev/sd?1; do
            [ -b "$dev" ] && sync_usb "$dev" && break
        done
        if [ -n "$SYNCED_DEV" ] && [ ! -b "$SYNCED_DEV" ]; then
            echo "USB removed: $SYNCED_DEV"
            SYNCED_DEV=""
            SYNCED_COUNT=0
        fi
        sleep 10
    done
}

echo "Starting MPD..."
mpd /etc/mpd.conf || true
sleep 5

for dev in /dev/sda1 /dev/sdb1; do
    [ -b "$dev" ] && { sync_usb "$dev"; break; }
done

echo "Building playlist..."
mpc -p 6600 update --wait || true
mpc -p 6600 clear || true
mpc -p 6600 listall | mpc -p 6600 add || true
TOTAL=$(mpc -p 6600 playlist | wc -l)
echo "Total tracks: $TOTAL"
mpc -p 6600 repeat on || true
mpc -p 6600 random on || true
[ "$TOTAL" -gt 0 ] && mpc -p 6600 play || true
echo "Playback started."

usb_watch &
wait
