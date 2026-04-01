#!/bin/bash
set -e

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
        inotifywait -e create /dev 2>/dev/null | while read -r dir event dev; do
            case "$dev" in
                sd[a-z]1|sd[a-z])
                    sleep 2
                    sync_usb "/dev/$dev"
                    ;;
            esac
        done
        sleep 5
    done
}

# mpd.conf 更新（USB のみ）
cat > /etc/mpd.conf << 'MPDEOF'
music_directory     "/music/usb"
db_file             "/var/lib/mpd/database"
log_file            "/var/log/mpd/mpd.log"
pid_file            "/run/mpd/mpd.pid"
state_file          "/var/lib/mpd/state"

user                "root"
bind_to_address     "0.0.0.0"
port                "6600"

auto_update         "yes"
auto_update_depth   "0"

decoder {
    plugin          "ffmpeg"
    enabled         "yes"
}

audio_output {
    type            "pulse"
    name            "balena-sound"
    server          "localhost"
    sink            "balena-sound.input"
}

input {
    plugin          "curl"
}
MPDEOF

# MPD起動
echo "Starting MPD..."
mpd /etc/mpd.conf
sleep 5

echo "Updating music database..."
mpc -p 6600 update --wait

echo "Building playlist..."
mpc -p 6600 clear
mpc -p 6600 listall | mpc -p 6600 add
TOTAL=$(mpc -p 6600 playlist | wc -l)
echo "Total tracks: $TOTAL"

mpc -p 6600 repeat on
mpc -p 6600 random off
[ "$TOTAL" -gt 0 ] && mpc -p 6600 play
echo "Playback started."

usb_watch &

wait
