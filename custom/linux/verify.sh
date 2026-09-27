#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
artifact="$repo/artifacts/linux"
runtime="$repo/artifacts/runtime-linux-x64"
mkdir -p "$runtime" "$artifact/fixtures"
python3 - "$artifact" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); manifest=json.loads((root/'electron-runtime-linux-x64.json').read_text())
with (root/manifest['asset']).open('rb') as stream:
 assert hashlib.file_digest(stream,'sha256').hexdigest()==manifest['sha256']
PY
unzip -q -o "$artifact/electron-v44.4.4-linux-x64-ac3-eac3.zip" -d "$runtime"
chmod +x "$runtime/electron" "$runtime/chrome-sandbox"
for codec in ac3 eac3; do
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i sine=frequency=440:sample_rate=48000 \
    -t 1 -ac 2 -c:a "$codec" -b:a 192k "$artifact/fixtures/$codec.mp4"
done
timeout 120 xvfb-run -a "$runtime/electron" "$repo/custom/linux/smoke.cjs" "$artifact/fixtures" "$artifact/codec-smoke.json"
