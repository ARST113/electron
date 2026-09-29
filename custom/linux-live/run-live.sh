#!/usr/bin/env bash
# Live AC3/EAC3 playback check for the released Linux runtime.
#
# Takes real samples out of a live stream URL with HTTP range requests and plays
# them in the published custom Electron runtime under Xvfb, capturing the decoded
# audio to WAV files. This is the check that the headless decodeAudioData probe in
# the build pipeline cannot provide.
#
# Usage: run-live.sh <stream-url> [release-tag] [start-seconds] [seconds]
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
url=${1:?stream URL is required}
release=${2:-v44.4.4-linux-x64-ac3-eac3-r4a1}
start=${3:-130}
length=${4:-20}
artifact="$repo/artifacts/linux-live"
runtime="$artifact/runtime"
mkdir -p "$artifact"

asset=electron-v44.4.4-linux-x64-ac3-eac3.zip
if [[ ! -x "$runtime/electron" ]]; then
  echo "Downloading $asset from release $release"
  curl -fL --retry 3 -o "$artifact/$asset" \
    "https://github.com/${GITHUB_REPOSITORY:-ARST113/electron}/releases/download/$release/$asset"
  unzip -q -o "$artifact/$asset" -d "$runtime"
  chmod +x "$runtime/electron" "$runtime/chrome-sandbox" 2>/dev/null || true
fi
[[ "$(cat "$runtime/version")" == '44.4.4' ]] || { echo 'Unexpected runtime version' >&2; exit 1; }
ls -lh "$runtime/electron" "$runtime/libffmpeg.so"
sha256sum "$runtime/electron" "$runtime/libffmpeg.so" | tee "$artifact/runtime-hashes.txt"

echo '===== stream codecs ====='
ffprobe -v error -show_entries stream=index,codec_type,codec_name,channels,sample_rate \
  -of json "$url" > "$artifact/stream-info.json" || echo '::warning::ffprobe failed on the live stream'
cat "$artifact/stream-info.json" || true

# Audio stream positions of a typical BluRay remux: a:0 is the first AC3 5.1
# track, a:5 is an EAC3 7.1 track. Overridable for other releases.
ac3_map=${AC3_MAP:-0:a:0}
eac3_map=${EAC3_MAP:-0:a:5}

cut() {
  local map=$1 name=$2
  shift 2
  echo "Cutting $name from $map"
  if ! timeout 900 ffmpeg -hide_banner -loglevel warning -y -ss "$start" -t "$length" -i "$url" \
    -map 0:v:0 -map "$map" -c copy -movflags +faststart -f mp4 "$artifact/$name.mp4" \
    2> "$artifact/cut-$name.log"; then
    echo "::warning::cutting $name failed"
    sed -n '1,40p' "$artifact/cut-$name.log" || true
    return 1
  fi
  ffprobe -v error -show_entries stream=index,codec_type,codec_name,channels -of csv "$artifact/$name.mp4" \
    > "$artifact/$name-streams.txt" || true
  cat "$artifact/$name-streams.txt"
  ls -lh "$artifact/$name.mp4"
}

cut "$ac3_map" sample-ac3 || true
cut "$eac3_map" sample-eac3 || true

play() {
  local file=$1 name=$2 seconds=$3
  [[ -f "$file" ]] || { echo "::warning::$file is missing, skipping $name"; return 0; }
  echo "===== playing $name ====="
  timeout 300 xvfb-run -a "$runtime/electron" "$repo/custom/linux-live/playback.cjs" \
    "$file" "$artifact/$name.json" "$seconds" "$artifact/$name.wav" \
    --no-sandbox --disable-gpu --disable-dev-shm-usage --user-data-dir="$artifact/profile-$name" \
    || echo "::warning::$name probe exited non-zero"
}

play "$artifact/sample-ac3.mp4" live-ac3 20
play "$artifact/sample-eac3.mp4" live-eac3 20

python3 - "$artifact" <<'PY'
import json
import pathlib
import sys

artifact = pathlib.Path(sys.argv[1])
reports = {}
for name in ('live-ac3', 'live-eac3'):
    path = artifact / f'{name}.json'
    reports[name] = json.loads(path.read_text()) if path.is_file() else {}
    report = reports[name]
    print(f'{name}: pass={report.get("pass")} rms={report.get("rms")} peak={report.get("peak")} '
          f'seconds={report.get("capturedSeconds")} audioBytes={report.get("decodedAudioBytes")} '
          f'mediaError={report.get("mediaError")}')
summary = {
    name: {
        'pass': bool(report.get('pass')),
        'rms': report.get('rms'),
        'peak': report.get('peak'),
        'capturedSeconds': report.get('capturedSeconds'),
        'decodedAudioBytes': report.get('decodedAudioBytes'),
        'mediaError': report.get('mediaError'),
    }
    for name, report in reports.items()
}
(artifact / 'live-verdict.json').write_text(json.dumps(summary, indent=2) + '\n')
if not reports['live-ac3'].get('pass'):
    raise SystemExit('The AC3 sample produced no audio in the released runtime')
if reports['live-eac3'] and not reports['live-eac3'].get('pass'):
    raise SystemExit('The EAC3 sample produced no audio in the released runtime')
print('Live playback verdict written')
PY
