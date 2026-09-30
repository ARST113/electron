#!/usr/bin/env bash
# Packages Lampa as a universal macOS bundle: one .dmg that runs natively on both
# Intel and Apple Silicon.
#
# Usage: package.sh <Lampa checkout> <runtime directory containing a universal Electron.app>
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
app=${1:?Path to the pinned Lampa Desktop checkout is required}
runtime=${2:?Path to the universal Electron runtime is required}
app=$(cd "$app" && pwd)
runtime=$(cd "$runtime" && pwd)
artifact="$repo/artifacts/macos-universal"
mkdir -p "$artifact"

[[ -d "$runtime/Electron.app" ]] || { echo "Electron.app not found in $runtime" >&2; exit 1; }
test -f "$runtime/version"
[[ "$(cat "$runtime/version")" == "44.4.4" ]]

echo '===== universal runtime ====='
lipo -info "$runtime/Electron.app/Contents/MacOS/Electron"
lipo -info "$runtime/Electron.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"
for arch in x86_64 arm64; do
  lipo -info "$runtime/Electron.app/Contents/MacOS/Electron" | grep -q "$arch" || {
    echo "The runtime is missing the $arch slice" >&2
    exit 1
  }
done

export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export CSC_IDENTITY_AUTO_DISCOVERY=false
export CSC_FOR_PULL_REQUEST=true
export ELECTRON_BUILDER_CACHE="${ELECTRON_BUILDER_CACHE:-$HOME/.cache/electron-builder}"

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

# Subtitle tools must be universal as well: fetch both architectures and join them.
# shellcheck source=/dev/null
export LAMPA_FFMPEG_ARCH=x64
source "$repo/custom/macos/fetch-ffmpeg.sh"
x64_ffmpeg="$FFMPEG_BIN"
x64_ffprobe="$FFPROBE_BIN"
# shellcheck source=/dev/null
export LAMPA_FFMPEG_ARCH=arm64
source "$repo/custom/macos/fetch-ffmpeg.sh"
arm64_ffmpeg="$FFMPEG_BIN"
arm64_ffprobe="$FFPROBE_BIN"

mkdir -p "$app/.cache/subtitle-tools"
join_tool() {
  local name=$1
  local first=$2
  local second=$3
  if [[ -n "$first" && -n "$second" ]]; then
    lipo -create "$first" "$second" -output "$app/.cache/subtitle-tools/$name"
    chmod +x "$app/.cache/subtitle-tools/$name"
    lipo -info "$app/.cache/subtitle-tools/$name"
  elif [[ -n "$first" ]]; then
    echo "::warning::only the x86_64 $name is available"
    cp -f "$first" "$app/.cache/subtitle-tools/$name"
  elif [[ -n "$second" ]]; then
    echo "::warning::only the arm64 $name is available"
    cp -f "$second" "$app/.cache/subtitle-tools/$name"
  else
    echo "::warning::no $name could be fetched at all"
  fi
}
join_tool ffmpeg "$x64_ffmpeg" "$arm64_ffmpeg"
join_tool ffprobe "$x64_ffprobe" "$arm64_ffprobe"
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
  // The Electron distribution is already universal, so a plain x64 packaging pass
  // simply copies the fat binaries into the bundle.
  artifactName: 'lampa-universal-${version}-macos-ac3.${ext}',
  mac: {
    ...pkg.build.mac,
    identity: null,
    target: [{ target: 'dmg', arch: ['x64'] }, { target: 'zip', arch: ['x64'] }],
  },
};
fs.writeFileSync('electron-builder-macos-universal.json', JSON.stringify(config, null, 2));
JS

"${yarn[@]}" exec electron-builder --mac --x64 --publish=never --config electron-builder-macos-universal.json

python3 - "$app" <<'PY'
import pathlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
bundle = app / 'dist/mac/Lampa.app'
assert bundle.is_dir(), f'no packaged bundle at {bundle}'
assert (bundle / 'Contents/Resources/app.asar').is_file()
tools = bundle / 'Contents/Resources/subtitle-tools'
assert (tools / 'ffmpeg').is_file(), f'subtitle tools were not bundled: {tools}'


def architectures(path):
    output = subprocess.run(['lipo', '-info', str(path)], check=True, capture_output=True, text=True).stdout
    return output


targets = {
    'Lampa': bundle / 'Contents/MacOS/Lampa',
    'framework': bundle / 'Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework',
    'ffmpeg': tools / 'ffmpeg',
}
report = {}
for name, path in targets.items():
    info = architectures(path)
    report[name] = info.strip()
    for arch in ('x86_64', 'arm64'):
        assert arch in info, f'{name} is missing the {arch} slice: {info}'
print('The packaged bundle is universal:')
for name, info in report.items():
    print(f'  {name}: {info}')
PY

codesign --force --deep --sign - "$app/dist/mac/Lampa.app"
codesign --verify --deep --strict --verbose=2 "$app/dist/mac/Lampa.app"

shopt -s nullglob
images=("$app"/dist/*.dmg)
archives=("$app"/dist/*.zip)
[[ ${#images[@]} == 1 ]] || { echo "Expected one dmg, found ${#images[@]}" >&2; exit 1; }
[[ ${#archives[@]} == 1 ]] || { echo "Expected one zip, found ${#archives[@]}" >&2; exit 1; }
cp -f "${images[0]}" "${archives[0]}" "$artifact/"
git -C "$app" rev-parse HEAD > "$artifact/lampa-revision.txt"
shasum -a 256 "$artifact"/*.dmg "$artifact"/*.zip | tee "$artifact/SHASUMS256.txt"
ls -lh "$artifact"
