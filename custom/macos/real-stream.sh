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

# macOS has neither timeout nor gtimeout by default, so every long call goes
# through this wrapper: GNU timeout when it exists, plain execution otherwise
# (the workflow step timeout is the backstop).
limit() {
  local seconds=$1
  shift
  if command -v timeout > /dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout > /dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  else
    "$@"
  fi
}


# --- ffmpeg -------------------------------------------------------------------
# Shared helper: static builds land in the tool cache and are exported as
# FFMPEG_BIN / FFPROBE_BIN. A missing ffprobe is fine, ffmpeg alone is enough.
# shellcheck source=/dev/null
source "$repo/custom/macos/fetch-ffmpeg.sh"
ffmpeg="$FFMPEG_BIN"
ffprobe="$FFPROBE_BIN"
[[ -n "$ffmpeg" ]] || { echo 'No ffmpeg available for the real-content check' >&2; exit 1; }
"$ffmpeg" -version > /dev/null 2>&1 || { echo "ffmpeg at $ffmpeg does not run" >&2; exit 1; }
echo "ffmpeg: $ffmpeg"
echo "ffprobe: ${ffprobe:-none}"

if [[ -n "$ffprobe" ]]; then
  limit 300 "$ffprobe" -v error -show_entries stream=index,codec_type,codec_name,channels,sample_rate \
    -of json "$url" > "$artifact/stream-info.json" || echo '::warning::ffprobe failed on the live stream'
else
  limit 300 "$ffmpeg" -hide_banner -i "$url" > /dev/null 2> "$artifact/stream-info.txt" || true
fi
[[ -s "$artifact/stream-info.json" ]] && cat "$artifact/stream-info.json" || cat "$artifact/stream-info.txt" 2>/dev/null || true

# --- playable sample cut straight from the live stream ------------------------
sample="$artifact/stream-sample-ac3.mp4"
start=${REAL_STREAM_START:-120}
length=${REAL_STREAM_SECONDS:-20}
echo "Cutting $length seconds from $start s of the live stream"
if ! limit 900 "$ffmpeg" -hide_banner -loglevel warning -y -ss "$start" -t "$length" -i "$url" \
  -map 0:v:0 -map 0:a:0 -c copy -movflags +faststart -f mp4 "$sample" 2> "$artifact/stream-cut.log"; then
  echo '::warning::seek failed, cutting from the beginning of the stream'
  limit 900 "$ffmpeg" -hide_banner -loglevel warning -y -t "$length" -i "$url" \
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
  echo '::warning::no playable sample was cut, recording the failure'
  python3 - "$artifact" <<'PY'
import json
import pathlib
import sys

artifact = pathlib.Path(sys.argv[1])
cut = (artifact / 'stream-cut.log')
verdict = {
    'rawContainerPlayed': None,
    'samplePlayed': False,
    'reason': 'the live stream could not be cut into a playable sample',
    'cutLog': cut.read_text()[-2000:] if cut.is_file() else None,
}
(artifact / 'stream-verdict.json').write_text(json.dumps(verdict, indent=2) + '\n')
print(json.dumps(verdict, indent=2))
raise SystemExit('Could not cut a playable sample from the live stream')
PY
fi
