#!/usr/bin/env bash
# Packages Lampa Desktop for macOS x86_64 with the verified Electron runtime.
#
# Usage: package.sh <Lampa checkout> <runtime directory containing Electron.app>
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
app=${1:?Path to the pinned Lampa Desktop checkout is required}
runtime=${2:?Path to the unpacked Electron runtime is required}
app=$(cd "$app" && pwd)
runtime=$(cd "$runtime" && pwd)
artifact="$repo/artifacts/macos"
mkdir -p "$artifact"

[[ -d "$runtime/Electron.app" ]] || {
  echo "Electron.app not found in $runtime" >&2
  exit 1
}
test -f "$runtime/version"
[[ "$(cat "$runtime/version")" == "44.4.4" ]]

export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export CSC_IDENTITY_AUTO_DISCOVERY=false
export CSC_FOR_PULL_REQUEST=true
# Keep electron-builder's cache inside the persistent workspace so repeat runs
# do not re-download its helper binaries.
export ELECTRON_BUILDER_CACHE="${ELECTRON_BUILDER_CACHE:-$HOME/.cache/electron-builder}"

cd "$app"
# The app is nested under Electron's controller checkout. Isolate Yarn config so
# the parent's yarnPath cannot replace the app's pinned Yarn.
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

node - "$runtime" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const pkg = require('./package.json');
if (pkg.devDependencies.electron !== '44.4.4') throw new Error('Lampa/Electron version mismatch');
const config = {
  ...pkg.build,
  electronDist: path.resolve(process.argv[2]),
  electronVersion: '44.4.4',
  // The bundled subtitle helpers are Windows executables; macOS relies on the
  // app's own extraction paths, so nothing is copied into the bundle.
  extraResources: [],
  artifactName: 'lampa-${arch}-${version}-macos-ac3.${ext}',
  mac: {
    ...pkg.build.mac,
    identity: null,
    target: [{ target: 'dmg', arch: ['x64'] }, { target: 'zip', arch: ['x64'] }],
  },
};
fs.writeFileSync('electron-builder-macos.json', JSON.stringify(config, null, 2));
JS

"${yarn[@]}" exec electron-builder --mac --x64 --publish=never --config electron-builder-macos.json

python3 - "$runtime" "$app" <<'PY'
import hashlib
import pathlib
import sys

runtime, app = (pathlib.Path(argument).resolve() for argument in sys.argv[1:])
relative = 'Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework'


def digest(path):
    sha = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            sha.update(chunk)
    return sha.hexdigest()


source = runtime / 'Electron.app' / relative
bundle = app / 'dist/mac/Lampa.app' / relative
assert bundle.is_file(), f'packaged application has no Electron framework: {bundle}'
assert digest(source) == digest(bundle), 'electron-builder replaced the custom Electron framework'
assert (app / 'dist/mac/Lampa.app/Contents/Resources/app.asar').is_file()
print('Packaged framework matches the verified runtime')
PY

node - "$app" <<'JS'
const path = require('node:path');
const pkg = require(path.join(process.argv[2], 'package.json'));
console.log('Lampa version:', pkg.version);
JS

# Ad-hoc signing keeps the bundle internally consistent for Gatekeeper and for
# the hardened runtime without requiring a Developer ID certificate. Notarized
# distribution is a separate step and needs real Apple credentials.
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
