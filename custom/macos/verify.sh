#!/usr/bin/env bash
# Verifies that the custom Electron runtime can decode AC3/EAC3 on this Mac.
#
# Two independent paths are probed:
#   1. decodeAudioData -> OfflineAudioContext, i.e. Chromium's FFmpeg audio
#      decoders filtered by media::GetAllowedAudioDecoders().
#   2. <video>/<audio> playback with a Web Audio tap, i.e. the platform
#      (AudioToolbox) decoders that Lampa actually uses during playback.
# Playback is captured into a WAV file so the result can be listened to.
#
# The step fails only when both paths fail for a codec, because in that case the
# runtime cannot play that track at all.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
runtime=${1:-"$repo/artifacts/macos/runtime-macos-x64"}
artifact="$repo/artifacts/macos"
electron="$runtime/Electron.app/Contents/MacOS/Electron"
fixtures="$repo/custom/macos/fixtures"

mkdir -p "$artifact"
[[ -x "$electron" ]] || {
  echo "Electron runtime not found at $electron" >&2
  exit 1
}
echo "Runtime: $electron"
du -sh "$runtime" || true

profile="$artifact/harness-profile"
run_probe() {
  local label=$1
  shift
  echo "----- $label -----"
  "$electron" "$@" --no-sandbox --disable-gpu --user-data-dir="$profile" || echo "::warning::$label exited non-zero"
}

set +e
run_probe "decoding probe" "$repo/custom/macos/smoke.cjs" "$fixtures" "$artifact/codec-smoke.json"
run_probe "playback probe ac3" "$repo/custom/macos/playback.cjs" "$fixtures/ac3.mp4" "$artifact/playback-ac3.json" 5 "$artifact/playback-ac3.wav"
run_probe "playback probe eac3" "$repo/custom/macos/playback.cjs" "$fixtures/eac3.mp4" "$artifact/playback-eac3.json" 5 "$artifact/playback-eac3.wav"
set -e

python3 - "$artifact" <<'PY'
import json
import pathlib
import sys

artifact = pathlib.Path(sys.argv[1])


def load(name):
    path = artifact / name
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text())
    except ValueError as error:
        return {'error': f'invalid JSON: {error}'}


smoke = load('codec-smoke.json')
playback = {codec: load(f'playback-{codec}.json') for codec in ('ac3', 'eac3')}
decoded = {entry.get('codec'): entry for entry in smoke.get('codecs', [])}

if smoke:
    print('Electron', smoke.get('electron'), 'Chromium', smoke.get('chrome'),
          smoke.get('platform'), smoke.get('arch'))

verdict = {'decodeToPcm': {}, 'playback': {}, 'sound': {}, 'supported': True, 'notes': []}
for codec in ('ac3', 'eac3'):
    decode_ok = bool(decoded.get(codec, {}).get('pass'))
    play = playback.get(codec, {})
    playback_ok = bool(play.get('pass'))
    verdict['decodeToPcm'][codec] = {
        'ok': decode_ok,
        'rms': decoded.get(codec, {}).get('rms'),
        'duration': decoded.get(codec, {}).get('duration'),
        'error': decoded.get(codec, {}).get('error'),
    }
    verdict['playback'][codec] = {
        'ok': playback_ok,
        'rms': play.get('rms'),
        'peak': play.get('peak'),
        'capturedSeconds': play.get('capturedSeconds'),
        'decodedAudioBytes': play.get('decodedAudioBytes'),
        'mediaError': play.get('mediaError'),
        'playError': play.get('playError'),
        'wav': play.get('wav'),
    }
    verdict['sound'][codec] = playback_ok
    print(f'{codec}: decodeAudioData={"ok" if decode_ok else "FAIL"} '
          f'playback={"ok" if playback_ok else "FAIL"} '
          f'rms={play.get("rms")} peak={play.get("peak")} '
          f'bytes={play.get("decodedAudioBytes")} seconds={play.get("capturedSeconds")}')
    if not decode_ok and not playback_ok:
        verdict['supported'] = False
    if playback_ok and not decode_ok:
        verdict['notes'].append(
            f'{codec}: platform (AudioToolbox) decoding works, FFmpeg decodeAudioData does not; '
            'in-app playback is fine, Web Audio decoding of raw AC3/EAC3 is not')

(artifact / 'codec-verdict.json').write_text(json.dumps(verdict, indent=2) + '\n')
print(json.dumps(verdict, indent=2))

if not verdict['supported']:
    print('Neither decoding path produced PCM for one of the codecs', file=sys.stderr)
    raise SystemExit(1)
PY

ls -lh "$artifact" | sed -n '1,40p'
