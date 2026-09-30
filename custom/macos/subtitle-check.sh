#!/usr/bin/env bash
# Verifies that the packaged bundle probes and extracts real subtitles on its own,
# using the application's own modules and the tools inside the bundle.
#
# Usage: subtitle-check.sh <Lampa.app path> [stream url]
set -uo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
app=${1:?path to Lampa.app is required}
url=${2:-${LAMPA_TEST_STREAM_URL:-}}
artifact="$repo/artifacts/macos"
mkdir -p "$artifact"

if [[ -z "$url" ]]; then
  echo 'No stream URL supplied, the subtitle check needs one and is skipped'
  exit 0
fi
[[ -d "$app" ]] || { echo "Lampa.app not found at $app" >&2; exit 1; }

resources="$app/Contents/Resources"
echo 'Bundled subtitle tools:'
ls -lh "$resources/subtitle-tools" 2>/dev/null || echo '::warning::nothing is bundled under subtitle-tools'

node "$repo/custom/macos/subtitle-check.mjs" \
  "$repo/lampa-app" "$resources" "$url" \
  "$artifact/subtitle-verdict.json" "$artifact/subtitle-sample.vtt" \
  "${SUBTITLE_INDEX:-}" "${SUBTITLE_START:-60}"
status=$?

head -c 600 "$artifact/subtitle-sample.vtt" 2>/dev/null || true
echo
if [[ $status -ne 0 ]]; then
  echo '::warning::the subtitle check did not pass'
fi
exit $status
