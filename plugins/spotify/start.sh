#!/usr/bin/env bash

if [[ -n "$SOUND_DISABLE_SPOTIFY" ]]; then
  echo "Spotify is disabled, exiting..."
  exit 0
fi

SOUND_DEVICE_NAME=${SOUND_DEVICE_NAME:-"balenaSound Spotify $(echo "$BALENA_DEVICE_UUID" | cut -c -4)"}
SOUND_SPOTIFY_BITRATE=${SOUND_SPOTIFY_BITRATE:-160}

if [[ -z ${SOUND_SPOTIFY_DISABLE_NORMALISATION+x} ]]; then
  set -- "$@" --enable-volume-normalisation
fi

if [[ -n "$SOUND_SPOTIFY_USERNAME" ]] && [[ -n "$SOUND_SPOTIFY_PASSWORD" ]]; then
  set -- "$@" --username "$SOUND_SPOTIFY_USERNAME" --password "$SOUND_SPOTIFY_PASSWORD"
fi

if [[ -z ${SOUND_SPOTIFY_ENABLE_CACHE+x} ]]; then
  set -- "$@" --disable-audio-cache
fi

echo "Starting Spotify plugin..."
echo "Device name: $SOUND_DEVICE_NAME"

CMD=(/usr/bin/librespot
  --backend pulseaudio
  --name "$SOUND_DEVICE_NAME"
  --bitrate "$SOUND_SPOTIFY_BITRATE"
  --cache /var/cache/raspotify
  --volume-ctrl linear
  --autoplay
  "$@")

while true; do
  "${CMD[@]}"
  echo "librespot exited, restarting in 2 seconds..."
  sleep 2
done
