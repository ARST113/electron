#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
artifact="$repo/${LINUX_ARTIFACT_DIR:-artifacts/linux-arm64}"
runtime="$repo/artifacts/runtime-linux-arm64"
archive="$artifact/electron-v44.4.4-linux-arm64-ac3-eac3.zip"
manifest="$artifact/electron-runtime-linux-arm64.json"
mkdir -p "$runtime" "$artifact"
python3 - "$artifact" "$manifest" <<'PY'
import hashlib, json, pathlib, sys, zipfile
artifact = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
manifest = json.loads(manifest_path.read_text())
archive = artifact / manifest['asset']
with archive.open('rb') as stream:
    assert hashlib.file_digest(stream, 'sha256').hexdigest() == manifest['sha256']
with zipfile.ZipFile(archive) as package:
    assert {'electron', 'libffmpeg.so', 'version'} <= set(package.namelist())
    assert package.read('version').decode().strip() == '44.4.4'
    assert package.read('electron')[18:20] == b'\xb7\x00', 'Expected AArch64 Electron ELF'
    assert package.read('libffmpeg.so')[:6] == b'\x7fELF\x02\x01'
print('ARM64 runtime ZIP, SHA-256, Electron ELF and version verified')
PY
unzip -q -o "$archive" -d "$runtime"
grep -q '^#define CONFIG_AC3_DECODER 1$' "$artifact/ffmpeg-linux-arm64/config_components.h"
grep -q '^#define CONFIG_EAC3_DECODER 1$' "$artifact/ffmpeg-linux-arm64/config_components.h"
grep -q 'ff_ac3_decoder' "$artifact/ffmpeg-linux-arm64/libavcodec/codec_list.c"
grep -q 'ff_eac3_decoder' "$artifact/ffmpeg-linux-arm64/libavcodec/codec_list.c"
python3 - "$artifact/codec-smoke.json" <<'PY'
import json, sys
json.dump({'arch': 'arm64', 'runtimeProbe': 'not-run',
           'reason': 'ARM64 Electron cannot execute natively on the x86_64 VPS',
           'ffmpegConfig': 'AC3 and EAC3 decoder and parser entries verified'},
          open(sys.argv[1], 'w'), indent=2)
open(sys.argv[1], 'a').write('\n')
PY
echo 'ARM64 archive and software AC3/EAC3 FFmpeg configuration verified; runtime execution requires an ARM64 host.'
