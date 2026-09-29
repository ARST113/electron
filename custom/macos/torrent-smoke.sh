#!/usr/bin/env bash
# Real torrent check.
#
# Starts the very same TorrServer build that Lampa downloads at runtime, feeds it
# a torrent with an AC3 5.1 track, waits for the pieces, plays the TorrServer
# stream in the custom Electron runtime and captures the decoded audio to a WAV
# file. Without LAMPA_TORRENT_MAGNET the sample committed in custom/macos/fixtures
# is seeded locally over a private tracker, so the check always has a peer.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
runtime=${1:-"$repo/artifacts/macos/runtime-macos-x64"}
artifact="$repo/artifacts/macos"
electron="$runtime/Electron.app/Contents/MacOS/Electron"
mkdir -p "$artifact"
[[ -x "$electron" ]] || { echo "Electron runtime not found at $electron" >&2; exit 1; }

torr_port=${TORRSERVER_PORT:-8090}
tracker_port=${TORRENT_TRACKER_PORT:-8099}
magnet=${LAMPA_TORRENT_MAGNET:-}
tools="$HOME/.cache/lampa-macos-torrent-tools"
mkdir -p "$tools"
seeder_pid=""
torrserver_pid=""

cleanup() {
  [[ -n "$seeder_pid" ]] && kill "$seeder_pid" 2>/dev/null || true
  [[ -n "$torrserver_pid" ]] && kill "$torrserver_pid" 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -d "$tools/node_modules/webtorrent" ]]; then
  npm install --prefix "$tools" --no-audit --no-fund webtorrent bittorrent-tracker
fi

if [[ -z "$magnet" ]]; then
  cp -f "$repo/custom/macos/torrent-seed.mjs" "$tools/torrent-seed.mjs"
  echo "Seeding the committed AC3 5.1 sample over http://127.0.0.1:$tracker_port/announce"
  (cd "$tools" && node torrent-seed.mjs "$repo/custom/macos/fixtures/torrent-sample.mkv" "$tracker_port" \
    > "$artifact/torrent-seeder.log" 2>&1) &
  seeder_pid=$!
  for _ in $(seq 1 120); do
    magnet=$(sed -n 's/^SEED_READY //p' "$artifact/torrent-seeder.log" | head -n 1)
    [[ -n "$magnet" ]] && break
    kill -0 "$seeder_pid" 2>/dev/null || break
    sleep 2
  done
  [[ -n "$magnet" ]] || { echo 'Seeder did not publish a magnet URI' >&2; cat "$artifact/torrent-seeder.log" >&2; exit 1; }
fi
echo "Magnet: ${magnet:0:120}..."

echo '===== TorrServer ====='
release=$(curl -fsSL https://api.github.com/repos/YouROK/TorrServer/releases/latest \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
echo "TorrServer release: $release"
torrserver="$tools/torrserver"
curl -fL --retry 3 -o "$torrserver" \
  "https://github.com/YouROK/TorrServer/releases/download/$release/TorrServer-darwin-amd64"
chmod +x "$torrserver"
xattr -c "$torrserver" 2>/dev/null || true

"$torrserver" --port "$torr_port" --ip 127.0.0.1 \
  --torrentsdir "$tools/torrents" --logpath "$artifact/torrserver.log" \
  > "$artifact/torrserver-stdout.log" 2>&1 &
torrserver_pid=$!

api="http://127.0.0.1:$torr_port"
for _ in $(seq 1 60); do
  if curl -fsS "$api/echo" > /dev/null 2>&1; then break; fi
  kill -0 "$torrserver_pid" 2>/dev/null || { echo 'TorrServer died during startup' >&2; cat "$artifact/torrserver-stdout.log" >&2; exit 1; }
  sleep 2
done
curl -fsS "$api/echo" > "$artifact/torrserver-echo.json"
cat "$artifact/torrserver-echo.json"

add=$(python3 -c 'import json,sys; print(json.dumps({"action":"add","link":sys.argv[1],"save_to_db":True,"title":"lampa-ci-sample"}))' "$magnet")
curl -fsS -X POST "$api/torrents" -H 'Content-Type: application/json' -d "$add" \
  | tee "$artifact/torrserver-add.json"

hash=$(python3 -c '
import re, sys
magnet = sys.argv[1]
match = re.search(r"btih:([0-9a-zA-Z]+)", magnet)
print(match.group(1).lower() if match else "")
' "$magnet")
[[ -n "$hash" ]] || { echo "Could not extract an infohash from the magnet" >&2; exit 1; }

echo '===== waiting for pieces ====='
for attempt in $(seq 1 90); do
  status=$(curl -fsS -X POST "$api/torrents" -H 'Content-Type: application/json' \
    -d "{\"action\":\"get\",\"hash\":\"$hash\"}" || echo '{}')
  echo "$status" > "$artifact/torrserver-status.json"
  ready=$(python3 - "$artifact/torrserver-status.json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    data = {}
size = data.get('torrent_size') or 0
loaded = data.get('loaded_size') or 0
stat = data.get('stat')
print('yes' if (size and loaded >= min(size, 256 * 1024)) or stat in (2, 3) else 'no')
PY
)
  [[ "$ready" == yes ]] && { echo "pieces available after $((attempt * 5))s"; break; }
  sleep 5
done

stream="http://127.0.0.1:$torr_port/stream?link=$hash&index=1&play"
playlist=$(curl -fsS "http://127.0.0.1:$torr_port/stream?link=$hash&index=1&m3u" || true)
printf '%s\n' "$playlist" > "$artifact/torrserver-playlist.m3u"
found=$(printf '%s\n' "$playlist" | grep -Eo 'http://127\.0\.0\.1:[0-9]+/stream/[^" ]+' | head -n 1 || true)
[[ -n "$found" ]] && stream="$found"
echo "Stream URL: $stream"

"$electron" "$repo/custom/macos/playback.cjs" "$stream" "$artifact/torrent-playback.json" 30 "$artifact/torrent-audio.wav" \
  --no-sandbox --disable-gpu --user-data-dir="$artifact/torrent-profile" \
  || echo '::warning::torrent playback probe exited non-zero'

python3 - "$artifact" <<'PY'
import json
import pathlib
import sys

artifact = pathlib.Path(sys.argv[1])
report = json.loads((artifact / 'torrent-playback.json').read_text()) if (artifact / 'torrent-playback.json').is_file() else {}
print(json.dumps(report, indent=2))
if not report.get('pass'):
    raise SystemExit('Torrent playback produced no audio')
print('Torrent playback captured',
      report.get('capturedSeconds'), 'seconds at RMS', report.get('rms'))
PY
