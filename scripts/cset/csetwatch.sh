#!/bin/bash
# Saves a Blackmagic camera's state as a preset every few seconds and keeps each one that differs from the last.
# Change one setting on the camera at a time, then csetdiff.py the snapshots either side of it: how the PYXIS's
# status text and de-squeeze fields were found (docs/pyxis-controls.md, Presets).
#
#   scripts/cset/csetwatch.sh <camera address> [out dir] [seconds between saves]
#   scripts/cset/csetdiff.py out/03-123133.cset out/04-123139.cset
set -u
CAM=${1:?camera address, e.g. 172.27.250.13}
OUT=${2:-cset-watch}
EVERY=${3:-3}
B="https://$CAM/control/api/v1/presets"
NAME=TilesWatch.cset
TMP=$(mktemp)
mkdir -p "$OUT"
trap 'curl -sk -X DELETE -o /dev/null "$B/$NAME"; rm -f "$TMP"; exit' INT TERM
last=""
i=0
while :; do
  curl -sk -X DELETE -o /dev/null "$B/$NAME"
  curl -sk -X PUT -o /dev/null "$B/$NAME"
  # The camera answers the save before it has written the file (404 until then).
  ok=0
  for _ in $(seq 1 30); do
    [ "$(curl -sk -o "$TMP" -w '%{http_code}' "$B/$NAME")" = 200 ] && { ok=1; break; }
    sleep 0.1
  done
  curl -sk -X DELETE -o /dev/null "$B/$NAME"
  if [ $ok = 1 ]; then
    sum=$(md5 -q "$TMP" 2>/dev/null || md5sum "$TMP" | cut -d' ' -f1)
    if [ "$sum" != "$last" ]; then
      f=$(printf '%s/%02d-%s.cset' "$OUT" "$i" "$(date +%H%M%S)")
      cp "$TMP" "$f" && echo "$f"
      last=$sum
      i=$((i + 1))
    fi
  else
    echo "$(date +%T) no preset from the camera" >&2
  fi
  sleep "$EVERY"
done
