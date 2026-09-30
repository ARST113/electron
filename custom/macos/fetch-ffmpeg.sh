#!/usr/bin/env bash
# Ensures static macOS builds of ffmpeg and ffprobe exist and exports
# FFMPEG_BIN / FFPROBE_BIN. Sourced by other scripts.
#
# The target architecture follows LAMPA_FFMPEG_ARCH (x64 by default, arm64 for
# Apple Silicon bundles) and each architecture keeps its own cache file.
#
# Sources, in order:
#   1. ffmpeg-static release assets (single Mach-O binaries, ffmpeg and ffprobe).
#   2. evermeet.cx for x86_64 ffmpeg only: its "ffprobe" archive actually ships
#      another ffmpeg build, which is why the bundle once had no ffprobe.
#   3. the imageio-ffmpeg wheel, x86_64 ffmpeg only, as a last resort.
#
# Nothing here may abort the caller: a missing ffprobe is tolerable for codec
# probing (ffmpeg's stderr works too), and every acquisition step is optional.
tools=${LAMPA_TOOL_CACHE:-$HOME/.cache/lampa-macos-tools}
arch=${LAMPA_FFMPEG_ARCH:-x64}
mkdir -p "$tools"
release=https://github.com/eugeneware/ffmpeg-static/releases/latest/download

case "$arch" in
  arm64) file_arch='arm64'; suffix='-arm64' ;;
  *) arch='x64'; file_arch='x86_64'; suffix='' ;;
esac

valid() { # valid <path> <word that -version must print>
  local path=$1
  local word=$2
  if [[ ! -x "$path" ]]; then
    return 1
  fi
  if ! "$path" -version 2>/dev/null | head -n 1 | grep -qi -- "$word"; then
    return 1
  fi
  if command -v file > /dev/null 2>&1; then
    if ! file "$path" | grep -q "$file_arch"; then
      echo "::warning::$path is not $file_arch, refetching"
      return 1
    fi
  fi
  return 0
}

for name in ffmpeg ffprobe; do
  target="$tools/$name$suffix"
  word="^$name version"
  if valid "$target" "$word"; then
    continue
  fi
  echo "Fetching a static $name build for macOS $arch"
  rm -f "$target"
  if curl -fL --retry 3 -o "$target.part" "$release/$name-darwin-$arch"; then
    mv -f "$target.part" "$target"
    # curl writes with the umask, so the downloaded binary is not executable and
    # every probe below would reject it. This used to be masked on x86_64 by the
    # evermeet fallback, whose zip restores the mode; arm64 has no fallback.
    chmod +x "$target"
  else
    echo "::warning::could not fetch $name for $arch from ffmpeg-static"
  fi
done

if [[ "$arch" == 'x64' ]] && ! valid "$tools/ffmpeg" '^ffmpeg version'; then
  echo '::warning::falling back to the evermeet archive for x86_64 ffmpeg'
  if curl -fL --retry 2 -o "$tools/ffmpeg.zip" https://evermeet.cx/ffmpeg/getrelease/zip; then
    rm -rf "$tools/ffmpeg-unpack"
    mkdir -p "$tools/ffmpeg-unpack"
    unzip -q -o "$tools/ffmpeg.zip" -d "$tools/ffmpeg-unpack" || true
    find "$tools/ffmpeg-unpack" -type f -name ffmpeg -exec mv -f {} "$tools/ffmpeg" \; 2>/dev/null || true
  fi
fi

FFMPEG_BIN=""
FFPROBE_BIN=""
if valid "$tools/ffmpeg$suffix" '^ffmpeg version'; then
  FFMPEG_BIN="$tools/ffmpeg$suffix"
fi
if valid "$tools/ffprobe$suffix" '^ffprobe version'; then
  FFPROBE_BIN="$tools/ffprobe$suffix"
fi

if [[ -z "$FFMPEG_BIN" && "$arch" == 'x64' ]]; then
  echo '::warning::falling back to the ffmpeg wheel from PyPI'
  python3 -m pip install --quiet --user imageio-ffmpeg > /dev/null 2>&1 || true
  wheel=$(python3 -c 'import imageio_ffmpeg, sys; sys.stdout.write(imageio_ffmpeg.get_ffmpeg_exe())' 2>/dev/null || true)
  if [[ -n "$wheel" && -x "$wheel" ]]; then
    chmod +x "$wheel" 2>/dev/null || true
    FFMPEG_BIN="$wheel"
  fi
fi

echo "ffmpeg ($arch): ${FFMPEG_BIN:-missing}"
echo "ffprobe ($arch): ${FFPROBE_BIN:-missing}"
export FFMPEG_BIN FFPROBE_BIN
