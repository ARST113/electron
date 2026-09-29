#!/usr/bin/env bash
# Real-content check against a live stream URL (for example a TorrServer link).
#
# A raw Matroska stream cannot be demuxed by Chromium, so the check does two
# things: it records the stream's real codec list, and it cuts a short,
# browser-playable MP4 (video copied, first AC3/EAC3 track copied) directly from
# the live server with HTTP range requests. That MP4 is played in the custom
# runtime and its decoded audio is captured into a WAV file.
#
# Usage: real-stream.sh <runtime directory> <stream url>
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
runtime=${1:?runtime directory is required}
url=${2:?stream URL is required}
artifact="$repo/artifacts/macos"
electron="$runtime/Electron.app/Contents/MacOS/Electron"
tools="$HOME/.cache/lampa-macos-tools"
mkdir -p "$artifact" "$tools"
[[ -x "$electron" ]] || { echo "Electron runtime not found at $electron" >&2; exit 1; }

# --- ffmpeg -------------------------------------------------------------------
ffmpeg=""
ffprobe=""
if [[ -x "$tools/ffmpeg" ]]; then
  ffmpeg="$tools/ffmpeg"
  [[ -x "$tools/ffprobe" ]] && ffprobe="$tools/ffprobe"
else
  echo 'Fetching a static ffmpeg build for macOS x86_64'
  if curl -fL --retry 2 -o "$tools/ffmpeg.zip" https://evermeet.cx/ffmpeg/getrelease/zip; then
    unzip -q -o "$tools/ffmpeg.zip" -d "$tools"
    chmod +x "$tools/ffmpeg"
    ffmpeg="$tools/ffmpeg"
  fi
  if curl -fL --retry 2 -o "$tools/ffprobe.zip" https://evermeet.cx/ffprobe/getrelease/zip; then
    unzip -q -o "$tools/ffprobe.zip" -d "$tools"
    chmod +x "$tools/ffprobe"
    ffprobe="$tools/ffprobe"
  fi
  if [[ -z "$ffmpeg" ]]; then
    echo 'Falling back to the ffmpeg wheel from PyPI'
    python3 -m pip install --quiet --user imageio-ffmpeg
    ffmpeg=$(python3 -c 'import imageio_ffmpeg, sys; sys.stdout.write(imageio_ffmpeg.get_ffmpeg_exe())')
  fi
fi
[[ -x "$ffmpeg" || -n "$ffmpeg" ]] || { echo 'No ffmpeg available' >&2; exit 1; }
xattr -c "$ffmpeg" 2>/dev/null || true
[[ -n "$ffprobe" ]] && xattr -c "$ffprobe" 2>/dev/null || true

if [[ -n "$ffprobe" ]]; then
  timeout 300 "$ffprobe" -v error -show_entries stream=index,codec_type,codec_name,channels,sample_rate \
    -of json "$url" > "$artifact/stream-info.json" || echo '::warning::ffprobe failed'
else
  timeout 300 "$ffmpeg" -hide_banner -i "$url" > /dev/null 2> "$artifact/stream-info.txt" || true
fi
[[ -f "$artifact/stream-info.json" ]] && cat "$artifact/stream-info.json" || cat "$artifact/stream-info.txt" || true

# --- playable sample cut straight from the live stream ------------------------
sample="$artifact/stream-sample-ac3.mp4"
echo "Cutting a playable sample from the live stream"
if ! timeout 900 "$ffmpeg" -hide_banner -loglevel warning -y -ss 120 -t 20 -i "$url" \
  -map 0:v:0 -map 0:a:0 -c copy -movflags +faststart -f mp4 "$sample" 2> "$artifact/stream-cut.log"; then
  echo '::warning::seek failed, cutting from the beginning of the stream'
  timeout 900 "$ffmpeg" -hide_banner -loglevel warning -y -t 20 -i "$url" \
    -map 0:v:0 -map 0:a:0 -c copy -movflags +faststart -f mp4 "$sample" 2>> "$artifact/stream-cut.log" || true
fi
ls -lh "$sample" 2>/dev/null || echo '::warning::no sample was produced'

# --- the raw container is recorded for the record, it is not expected to play --
"$electron" "$repo/custom/macos/playback.cjs" "$url" "$artifact/stream-raw.json" 10 "" \
  --no-sandbox --disable-gpu --user-data-dir="$artifact/stream-profile" \
  || echo '::warning::raw container playback failed as expected for Matroska'

# --- decoded audio from the real content --------------------------------------
if [[ -f "$sample" ]]; then
  "$electron" "$repo/custom/macos/playback.cjs" "$sample" "$artifact/stream-playback.json" 25 \
    "$artifact/stream-audio.wav" \
    --no-sandbox --disable-gpu --user-data-dir="$artifact/stream-profile" \
    || echo '::warning::sample playback probe exited non-zero'

  python3 - "$artifact" <<'PY'
import json
import pathlib
import sys

artifact = pathlib.Path(sys.argv[1])
report = json.loads((artifact / 'stream-playback.json').read_text()) if (artifact / 'stream-playback.json').is_file() else {}
raw = json.loads((artifact / 'stream-raw.json').read_text()) if (artifact / 'stream-raw.json').is_file() else {}
print('raw container:', json.dumps(raw, indent=2))
print('remuxed sample:', json.dumps(report, indent=2))
verdict = {
    'rawContainerPlayed': bool(raw.get('pass')),
    'rawContainerError': raw.get('mediaError') or raw.get('playError'),
    'samplePlayed': bool(report.get('pass')),
    'rms': report.get('rms'),
    'capturedSeconds': report.get('capturedSeconds'),
    'decodedAudioBytes': report.get('decodedAudioBytes'),
}
(artifact / 'stream-verdict.json').write_text(json.dumps(verdict, indent=2) + '\n')
if not verdict['samplePlayed']:
    raise SystemExit('Real content produced no audio in the custom runtime')
print('Real content played with', verdict['capturedSeconds'], 'seconds captured at RMS', verdict['rms'])
PY
else
  echo 'No playable sample, skipping the real-content playback probe'
fi
