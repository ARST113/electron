#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cpu=${LINUX_TARGET_CPU:-x64}
case "$cpu" in
  x64) default_base=/build/lampa-ci/electron-44-linux; args_file="$repo/custom/linux/args.gn" ;;
  arm64) default_base=/build/lampa-ci/electron-44-linux-arm64; args_file="$repo/custom/linux/args-arm64.gn" ;;
  *) echo "Unsupported Linux target CPU: $cpu" >&2; exit 2 ;;
esac
base=${LINUX_BASE:-$default_base}
artifact_dir=${LINUX_ARTIFACT_DIR:-artifacts/linux}
artifact="$repo/$artifact_dir"
mkdir -p "$base" "$artifact"
exec 9>"$base/.lock"
flock -n 9 || { echo 'Another Linux build owns the checkout'; exit 1; }
export DEPOT_TOOLS_UPDATE=0 DEPOT_TOOLS_METRICS=0
export GIT_AUTHOR_NAME='Lampa Linux Builder' GIT_COMMITTER_NAME='Lampa Linux Builder'
export GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
readarray -t pins < <(python3 - "$repo/custom/linux/pins.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
for key in ('electron_revision','chromium_revision','depot_tools_revision'):
 print(p[key])
PY
)
[[ ${#pins[@]} == 3 ]]
ensure_checkout() {
  local dir=$1 url=$2 revision=$3
  if [[ ! -d "$dir/.git" ]]; then
    mkdir -p "$dir"
    git -C "$dir" init
    git -C "$dir" remote add origin "$url"
  fi
  [[ $(git -C "$dir" remote get-url origin) == "$url" ]]
  if git -C "$dir" rev-parse --verify HEAD >/dev/null 2>&1; then
    # Electron's upstream patch system creates descendant commits in Chromium.
    git -C "$dir" merge-base --is-ancestor "$revision" HEAD || {
      echo "Unexpected source revision in $dir; refusing to reset it"; exit 1;
    }
  else
    git -C "$dir" fetch --depth=1 origin "$revision"
    git -C "$dir" -c advice.detachedHead=false checkout --detach FETCH_HEAD
  fi
}
if [[ ! -d "$base/src/.git" ]]; then
  available=$(df -PB1 "$base" | awk 'NR==2 {print $4}')
  (( available > 200 * 1024 * 1024 * 1024 )) || { echo 'Need 200 GiB free for initial checkout'; exit 1; }
fi
ensure_checkout "$base/depot_tools" https://chromium.googlesource.com/chromium/tools/depot_tools.git "${pins[2]}"
export PATH="$base/depot_tools:$PATH"
ensure_checkout "$base/src" https://chromium.googlesource.com/chromium/src.git "${pins[1]}"
ensure_checkout "$base/src/electron" https://github.com/electron/electron.git "${pins[0]}"
[[ $(git -C "$base/src/electron" rev-parse HEAD) == "${pins[0]}" ]]
cd "$base"
cat > .gclient <<EOF
solutions = [{
  'name': 'src/electron',
  'url': 'https://github.com/electron/electron.git',
  'deps_file': 'DEPS',
  'managed': False,
  'custom_vars': {
    'checkout_android': False,
    'checkout_clang_tidy': False,
    'checkout_pgo_profiles': False,
    'use_mtime_cache': False,
  },
}]
target_os = ['linux']
target_cpu = ['$cpu']
EOF
if [[ ! -f "$base/.synced" ]]; then
  gclient sync --no-history --nohooks -j6 2>&1 | tee "$artifact/sync.log"
  gclient runhooks 2>&1 | tee "$artifact/hooks.log"
  cp "$repo/custom/linux/pins.json" "$base/.synced"
fi
cmp "$repo/custom/linux/pins.json" "$base/.synced"
gclient revinfo > "$artifact/dependencies.txt"
cd "$base/src"
# gclient's GCS migration can remove Electron's hook-installed sysroot while
# reading dependency metadata. Restore the pinned Electron image afterwards.
sysroot_arch=amd64
[[ "$cpu" == arm64 ]] && sysroot_arch=arm64
python3 build/linux/sysroot_scripts/install-sysroot.py \
  --sysroots-json-path=electron/script/sysroots.json --arch="$cpu" 2>&1 | tee "$artifact/sysroot.log"
test -f "build/linux/debian_bullseye_${sysroot_arch}-sysroot/usr/include/stdio.h"
export PATH="$base/src/third_party/llvm-build/Release+Asserts/bin:$base/src/buildtools/linux64:$base/src/third_party/ninja:$PATH"
for patch in "$repo"/custom/linux/patches/*.patch; do
  if git apply --reverse --check "$patch" 2>/dev/null; then
    echo "Already applied: $(basename "$patch")"
  else
    git apply --check "$patch"
    git apply "$patch"
  fi
done
identity=$(cat "$repo/custom/linux/pins.json" "$repo"/custom/linux/patches/*.patch "$repo/custom/linux/build.sh" "$args_file" | sha256sum | cut -d' ' -f1)
if [[ ! -f "$base/.ffmpeg-linux-$cpu" || $(cat "$base/.ffmpeg-linux-$cpu") != "$identity" ]]; then
  python3 media/ffmpeg/scripts/build_ffmpeg.py linux "$cpu" --branding=Chrome 2>&1 | tee "$artifact/ffmpeg-build.log"
  (cd third_party/ffmpeg && bash chromium/scripts/copy_config.sh) > "$artifact/ffmpeg-configs.log"
  python3 media/ffmpeg/scripts/generate_gn.py 2>&1 | tee "$artifact/ffmpeg-gn.log"
  printf '%s\n' "$identity" > "$base/.ffmpeg-linux-$cpu"
fi
config="third_party/ffmpeg/chromium/config/Chrome/linux/$cpu"
grep -q '^#define CONFIG_AC3_DECODER 1$' "$config/config_components.h"
grep -q '^#define CONFIG_EAC3_DECODER 1$' "$config/config_components.h"
grep -q 'ff_ac3_decoder' "$config/libavcodec/codec_list.c"
grep -q 'ff_eac3_decoder' "$config/libavcodec/codec_list.c"
cp -a "$config" "$artifact/ffmpeg-linux-$cpu"
git -C third_party/ffmpeg diff --binary > "$artifact/ffmpeg-generated.patch"
git -C third_party/ffmpeg rev-parse HEAD > "$artifact/ffmpeg-revision.txt"
git diff --binary > "$artifact/chromium-software-codecs.patch"
cp "$repo/custom/linux/pins.json" "$artifact/"
out="out/Lampa_linux_${cpu}_ac3"
mkdir -p "$out"
cp "$args_file" "$out/args.gn"
gn gen "$out" 2>&1 | tee "$artifact/gn.log"
gn args "$out" --list --short > "$artifact/effective-args.txt"
grep -q '^enable_platform_ac3_eac3_audio = true$' "$artifact/effective-args.txt"
grep -q '^enable_passthrough_audio_codecs = false$' "$artifact/effective-args.txt"
available=$(df -PB1 "$base" | awk 'NR==2 {print $4}')
(( available > 60 * 1024 * 1024 * 1024 )) || { echo 'Need 60 GiB free before compiling'; exit 1; }
ninja -j8 -C "$out" electron:electron_dist_zip 2>&1 | tee "$artifact/ninja.log"
archive="electron-v44.4.4-linux-$cpu-ac3-eac3.zip"
cp "$out/dist.zip" "$artifact/$archive"
python3 "$repo/custom/linux/runtime-manifest.py" "$artifact" "$repo" "$cpu"
echo "Linux $cpu Electron runtime built; verification and RPM packaging follow."
