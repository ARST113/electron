#!/usr/bin/env bash
# Ensures static macOS builds of ffmpeg and ffprobe exist and exports
# FFMPEG_BIN / FFPROBE_BIN. Sourced by other scripts.
#
# Sources, in order:
#   1. ffmpeg-static release assets (single Mach-O binaries, ffmpeg and ffprobe).
#   2. evermeet.cx for ffmpeg only: its "ffprobe" archive actually ships another
#      ffmpeg build, which is exactly why the bundle once had no ffprobe.
#   3. the imageio-ffmpeg wheel, ffmpeg only, as a last resort.
#
# Nothing here may abort the caller: a missing ffprobe is tolerable for codec
# probing (ffmpeg's stderr works too), and every acquisition step is optional.
tools=${LAMPA_TOOL_CACHE:-$HOME/.cache/lampa-macos-tools}
mkdir -p "$tools"
release=https://github.com/eugeneware/ffmpeg-static/releases/latest/download

valid() { # valid <path> <word that -version must print>
  if [[ ! -x "$1" ]]; then
    return 1
  fi
  if "$1" -version 2>/dev/null | head -n 1 | grep -qi -- "$2"; then
    return 0
  fi
  return 1
}

if ! valid "$tools/ffmpeg" '^ffmpeg version'; then
  echo 'Fetching a static ffmpeg build for macOS x86_64'
  rm -f "$tools/ffmpeg"
  if curl -fL --retry 3 -o "$tools/ffmpeg.part" "$release/ffmpeg-darwin-x64"; then
    mv -f "$tools/ffmpeg.part" "$tools/ffmpeg"
  else
    echo '::warning::could not fetch ffmpeg from ffmpeg-static'
  fi
fi

if ! valid "$tools/ffprobe" '^ffprobe version'; then
  echo 'Fetching a static ffprobe build for macOS x86_64'
  rm -f "$tools/ffprobe"
  if curl -fL --retry 3 -o "$tools/ffprobe.part" "$release/ffprobe-darwin-x64"; then
    mv -f "$tools/ffprobe.part" "$tools/ffprobe"
  else
    echo '::warning::could not fetch ffprobe from ffmpeg-static'
  fi
fi

if ! valid "$tools/ffmpeg" '^ffmpeg version'; then
  echo '::warning::falling back to the evermeet archive for ffmpeg'
  if curl -fL --retry 2 -o "$tools/ffmpeg.zip" https://evermeet.cx/ffmpeg/getrelease/zip; then
    rm -rf "$tools/ffmpeg-unpack"
    mkdir -p "$tools/ffmpeg-unpack"
    unzip -q -o "$tools/ffmpeg.zip" -d "$tools/ffmpeg-unpack" || true
    find "$tools/ffmpeg-unpack" -type f -name ffmpeg -exec mv -f {} "$tools/ffmpeg" \; 2>/dev/null || true
  fi
fi

for candidate in ffmpeg ffprobe; do
  if [[ -f "$tools/$candidate" ]]; then
    chmod +x "$tools/$candidate" || true
    xattr -c "$tools/$candidate" 2>/dev/null || true
  fi
done

FFMPEG_BIN=""
FFPROBE_BIN=""
if valid "$tools/ffmpeg" '^ffmpeg version'; then
  FFMPEG_BIN="$tools/ffmpeg"
fi
if valid "$tools/ffprobe" '^ffprobe version'; then
  FFPROBE_BIN="$tools/ffprobe"
fi

if [[ -z "$FFMPEG_BIN" ]]; then
  echo '::warning::falling back to the ffmpeg wheel from PyPI'
  python3 -m pip install --quiet --user imageio-ffmpeg > /dev/null 2>&1 || true
  wheel=$(python3 -c 'import imageio_ffmpeg, sys; sys.stdout.write(imageio_ffmpeg.get_ffmpeg_exe())' 2>/dev/null || true)
  if [[ -n "$wheel" && -x "$wheel" ]]; then
    chmod +x "$wheel" 2>/dev/null || true
    FFMPEG_BIN="$wheel"
  fi
fi

echo "ffmpeg: ${FFMPEG_BIN:-missing}"
echo "ffprobe: ${FFPROBE_BIN:-missing}"
export FFMPEG_BIN FFPROBE_BIN
