#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
app=${1:?Path to the pinned Lampa Desktop checkout is required}
app=$(cd "$app" && pwd)
cpu=${LINUX_TARGET_CPU:-x64}
case "$cpu" in
  x64) builder_arch=x64; rpm_arch=x86_64 ;;
  arm64) builder_arch=arm64; rpm_arch=aarch64 ;;
  *) echo "Unsupported Linux target CPU: $cpu" >&2; exit 2 ;;
esac
export LINUX_BUILDER_ARCH="$builder_arch"
artifact_dir=${LINUX_ARTIFACT_DIR:-artifacts/linux}
artifact="$repo/$artifact_dir"
runtime="$repo/artifacts/runtime-linux-$cpu"
manifest_name="electron-runtime-linux-$cpu.json"
export ELECTRON_SKIP_BINARY_DOWNLOAD=1
cd "$app"
# The app is nested under Electron's controller checkout. Isolate Yarn config
# so the parent's yarnPath cannot replace the app's pinned Yarn 4.9.4.
export YARN_RC_FILENAME=.yarnrc-lampa-ci.yml
git show HEAD:.yarnrc.yml > "$YARN_RC_FILENAME"
# Corepack is local to the persistent build directory; no global Node changes.
tools=/build/lampa-ci/electron-44-linux/package-tools
if [[ ! -f "$tools/node_modules/corepack/dist/yarn.js" ]]; then
  npm install --prefix "$tools" --no-audit --no-fund corepack@0.34.1
fi
yarn=(node "$tools/node_modules/corepack/dist/yarn.js")
"${yarn[@]}" install --immutable
node --test test/autoUpdater.test.cjs test/subtitles.test.cjs test/matroska.test.cjs test/subtitleToolPath.test.cjs
node - "$runtime" <<'JS'
const fs = require('node:fs');
const pkg = require('./package.json');
if (pkg.devDependencies.electron !== '44.4.4') throw new Error('Lampa/Electron version mismatch');
const config = { ...pkg.build,
  electronDist: process.argv[2], electronVersion: '44.4.4', extraResources: [],
  artifactName: 'lampa-${arch}-${version}-linux-ac3.${ext}',
  linux: { ...pkg.build.linux, target: [{ target: 'rpm', arch: [process.env.LINUX_BUILDER_ARCH] }] }
};
fs.writeFileSync('electron-builder-linux.json', JSON.stringify(config, null, 2));
JS
LINUX_BUILDER_ARCH="$builder_arch" "${yarn[@]}" exec electron-builder --linux rpm --"$builder_arch" --publish=never --config electron-builder-linux.json
python3 - "$artifact" "$app" "$manifest_name" <<'PY'
import hashlib,json,pathlib,sys
artifact,app=map(pathlib.Path,sys.argv[1:3])
manifest=json.loads((artifact/sys.argv[3]).read_text())
binary=app/'dist/linux-unpacked/libffmpeg.so'
with binary.open('rb') as source:
    assert hashlib.file_digest(source,'sha256').hexdigest()==manifest['ffmpegSha256'], 'Packager replaced libffmpeg.so'
assert (app/'dist/linux-unpacked/resources/app.asar').is_file()
PY
shopt -s nullglob
rpms=(dist/*.rpm)
[[ ${#rpms[@]} == 1 ]] || { echo "Expected one $rpm_arch RPM"; exit 1; }
[[ $(rpm -qp --qf '%{ARCH}' "${rpms[0]}") == "$rpm_arch" ]]
rpm -qpl "${rpms[0]}" > "$artifact/rpm-files.txt"
rpm -qp --requires "${rpms[0]}" > "$artifact/rpm-requires.txt"
cp "${rpms[0]}" "$artifact/"
git rev-parse HEAD > "$artifact/lampa-revision.txt"
(cd "$artifact" && sha256sum ./*.rpm >> SHASUMS256.txt)
