#!/usr/bin/env bash
# Ensures static macOS builds of ffmpeg and ffprobe exist and exports
# FFMPEG_BIN / FFPROBE_BIN. Sourced by other scripts.
#
# Nothing in here may abort the caller: a missing ffprobe is tolerable (the codec
# list can be read from ffmpeg's stderr), and every acquisition step is optional.
tools=${LAMPA_TOOL_CACHE:-$HOME/.cache/lampa-macos-tools}
mkdir -p "$tools"

if [[ ! -x "$tools/ffmpeg" ]]; then
  echo 'Fetching a static ffmpeg build for macOS x86_64'
  if curl -fL --retry 2 -o "$tools/ffmpeg.zip" https://evermeet.cx/ffmpeg/getrelease/zip; then
    unzip -q -o "$tools/ffmpeg.zip" -d "$tools" || true
  else
    echo '::warning::static ffmpeg download failed'
  fi
fi
if [[ ! -x "$tools/ffprobe" ]]; then
  if curl -fL --retry 2 -o "$tools/ffprobe.zip" https://evermeet.cx/ffprobe/getrelease/zip; then
    unzip -q -o "$tools/ffprobe.zip" -d "$tools" || true
  else
    echo '::warning::static ffprobe download failed'
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
if [[ -x "$tools/ffmpeg" ]]; then
  FFMPEG_BIN="$tools/ffmpeg"
fi
if [[ -x "$tools/ffprobe" ]]; then
  FFPROBE_BIN="$tools/ffprobe"
fi

if [[ -z "$FFMPEG_BIN" ]]; then
  echo '::warning::falling back to the ffmpeg wheel from PyPI'
  python3 -m pip install --quiet --user imageio-ffmpeg > /dev/null 2>&1 || true
  FFMPEG_BIN=$(python3 -c 'import imageio_ffmpeg, sys; sys.stdout.write(imageio_ffmpeg.get_ffmpeg_exe())' 2>/dev/null || true)
  if [[ -n "$FFMPEG_BIN" ]]; then
    chmod +x "$FFMPEG_BIN" 2>/dev/null || true
  fi
fi

export FFMPEG_BIN FFPROBE_BIN
