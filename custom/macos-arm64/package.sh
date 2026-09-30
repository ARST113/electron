#!/usr/bin/env bash
# Packages Lampa Desktop for Apple Silicon with the verified arm64 Electron runtime.
#
# The bundle is built but never executed: this fleet has no arm64 machine. Every
# check here is therefore static (architecture, hashes, bundle layout).
#
# Usage: package.sh <Lampa checkout> <runtime directory containing Electron.app>
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
app=${1:?Path to the pinned Lampa Desktop checkout is required}
runtime=${2:?Path to the unpacked arm64 Electron runtime is required}
app=$(cd "$app" && pwd)
runtime=$(cd "$runtime" && pwd)
artifact="$repo/artifacts/macos-arm64"
mkdir -p "$artifact"

[[ -d "$runtime/Electron.app" ]] || { echo "Electron.app not found in $runtime" >&2; exit 1; }
test -f "$runtime/version"
[[ "$(cat "$runtime/version")" == "44.4.4" ]]
file "$runtime/Electron.app/Contents/MacOS/Electron" | grep -q arm64 || {
  echo 'The runtime is not arm64' >&2
  exit 1
}

export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export CSC_IDENTITY_AUTO_DISCOVERY=false
export CSC_FOR_PULL_REQUEST=true
export ELECTRON_BUILDER_CACHE="${ELECTRON_BUILDER_CACHE:-$HOME/.cache/electron-builder}"
export LAMPA_FFMPEG_ARCH=arm64

cd "$app"
export YARN_RC_FILENAME=.yarnrc-lampa-ci.yml
git show HEAD:.yarnrc.yml > "$YARN_RC_FILENAME"

tools="$HOME/.cache/lampa-macos-package-tools"
if [[ ! -f "$tools/node_modules/corepack/dist/yarn.js" ]]; then
  npm install --prefix "$tools" --no-audit --no-fund corepack@0.34.1
fi
yarn=(node "$tools/node_modules/corepack/dist/yarn.js")
"${yarn[@]}" install --immutable

if compgen -G "test/*.test.cjs" > /dev/null; then
  node --test test/*.test.cjs
fi

# arch64 subtitle tools travel inside the bundle for the same reason as on x64.
# shellcheck source=/dev/null
source "$repo/custom/macos/fetch-ffmpeg.sh"
mkdir -p "$app/.cache/subtitle-tools"
if [[ -n "$FFMPEG_BIN" ]]; then
  cp -f "$FFMPEG_BIN" "$app/.cache/subtitle-tools/ffmpeg"
  chmod +x "$app/.cache/subtitle-tools/ffmpeg"
else
  echo '::warning::no static arm64 ffmpeg is available'
fi
if [[ -n "$FFPROBE_BIN" ]]; then
  cp -f "$FFPROBE_BIN" "$app/.cache/subtitle-tools/ffprobe"
  chmod +x "$app/.cache/subtitle-tools/ffprobe"
else
  echo '::warning::no static arm64 ffprobe is available'
fi
ls -lh "$app/.cache/subtitle-tools" || true

node - "$runtime" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const pkg = require('./package.json');
if (pkg.devDependencies.electron !== '44.4.4') throw new Error('Lampa/Electron version mismatch');
const config = {
  ...pkg.build,
  electronDist: path.resolve(process.argv[2]),
  electronVersion: '44.4.4',
  extraResources: [
    { from: '.cache/subtitle-tools', to: 'subtitle-tools', filter: ['ffmpeg', 'ffprobe'] },
  ],
  artifactName: 'lampa-${arch}-${version}-macos-ac3.${ext}',
  mac: {
    ...pkg.build.mac,
    identity: null,
    target: [{ target: 'dmg', arch: ['arm64'] }, { target: 'zip', arch: ['arm64'] }],
  },
};
fs.writeFileSync('electron-builder-macos-arm64.json', JSON.stringify(config, null, 2));
JS

"${yarn[@]}" exec electron-builder --mac --arm64 --publish=never --config electron-builder-macos-arm64.json

python3 - "$runtime" "$app" <<'PY'
import hashlib
import pathlib
import subprocess
import sys

runtime, app = (pathlib.Path(argument).resolve() for argument in sys.argv[1:])
relative = 'Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework'


def digest(path):
    sha = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            sha.update(chunk)
    return sha.hexdigest()


bundle = app / 'dist/mac-arm64/Lampa.app'
if not bundle.is_dir():
    bundle = app / 'dist/mac/Lampa.app'
source = runtime / 'Electron.app' / relative
target = bundle / relative
assert target.is_file(), f'packaged application has no Electron framework: {target}'
assert digest(source) == digest(target), 'electron-builder replaced the custom Electron framework'
assert (bundle / 'Contents/Resources/app.asar').is_file()
tools = bundle / 'Contents/Resources/subtitle-tools'
assert (tools / 'ffmpeg').is_file(), f'ffmpeg was not bundled under {tools}'

types = subprocess.run(['file', str(bundle / 'Contents/MacOS/Lampa')], check=True, capture_output=True, text=True).stdout
assert 'arm64' in types, types
print('Packaged bundle is arm64, uses the verified framework and carries the subtitle tools')
print(types.strip())
PY

codesign --force --deep --sign - "$app/dist/mac-arm64/Lampa.app" 2>/dev/null \
  || codesign --force --deep --sign - "$app/dist/mac/Lampa.app"
codesign --verify --deep --strict --verbose=2 "$app/dist/mac-arm64/Lampa.app" 2>/dev/null \
  || codesign --verify --deep --strict --verbose=2 "$app/dist/mac/Lampa.app"

shopt -s nullglob
images=("$app"/dist/*.dmg)
archives=("$app"/dist/*.zip)
[[ ${#images[@]} == 1 ]] || { echo "Expected one dmg, found ${#images[@]}" >&2; exit 1; }
[[ ${#archives[@]} == 1 ]] || { echo "Expected one zip, found ${#archives[@]}" >&2; exit 1; }
cp -f "${images[0]}" "${archives[0]}" "$artifact/"
git -C "$app" rev-parse HEAD > "$artifact/lampa-revision.txt"
shasum -a 256 "$artifact"/*.dmg "$artifact"/*.zip | tee "$artifact/SHASUMS256.txt"
ls -lh "$artifact"
