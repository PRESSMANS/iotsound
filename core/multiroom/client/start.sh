#!/usr/bin/env bash
set -e

if [[ -n "$SOUND_DISABLE_MULTIROOM_CLIENT" ]]; then
  echo "Multiroom client is disabled, exiting..."
  exit 0
fi

SOUND_SUPERVISOR_PORT=${SOUND_SUPERVISOR_PORT:-80}
SOUND_SUPERVISOR="$(ip route | awk '/default / { print $3 }'):$SOUND_SUPERVISOR_PORT"
while ! curl --silent --output /dev/null "$SOUND_SUPERVISOR/ping"; do sleep 5; echo "Waiting for sound supervisor to start at $SOUND_SUPERVISOR"; done

MODE=$(curl --silent "$SOUND_SUPERVISOR/mode" || true)
SNAPSERVER=$(curl --silent "$SOUND_SUPERVISOR/multiroom/master" || true)

LATENCY=${SOUND_MULTIROOM_LATENCY:-500}

echo "Starting multi-room client..."
echo "- balenaSound mode: $MODE"
echo "- Target snapcast server: $SNAPSERVER"
echo "- Latency: $LATENCY ms"

if [[ -z $SOUND_DEVICE_NAME ]]; then
    SNAPCAST_CLIENT_ID=$BALENA_DEVICE_UUID
else
    SNAPCAST_CLIENT_ID=$(echo $SOUND_DEVICE_NAME | sed -e 's/[^A-Za-z0-9.-]/-/g')
fi

if [[ "$MODE" == "MULTI_ROOM" || "$MODE" == "MULTI_ROOM_CLIENT" ]]; then
  /usr/bin/snapclient \
    --host $SNAPSERVER \
    --latency $LATENCY \
    --hostID $SNAPCAST_CLIENT_ID \
    --player alsa \
    --reconnect \
    --logfilter *:error
else
  echo "Multi-room client disabled. Exiting..."
  exit 0
fi
