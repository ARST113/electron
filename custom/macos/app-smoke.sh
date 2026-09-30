#!/usr/bin/env bash
# Starts the packaged Lampa.app with a debugging port and proves that a window
# with a rendered document appears. Screenshot and DOM facts land in the artifact
# directory next to the other evidence.
#
# Usage: app-smoke.sh <Lampa.app path> <artifact directory>
set -uo pipefail

app=${1:?path to Lampa.app is required}
artifact=${2:?artifact directory is required}
port=${LAMPA_DEVTOOLS_PORT:-9333}
mkdir -p "$artifact"
[[ -d "$app" ]] || { echo "Lampa.app not found at $app" >&2; exit 1; }

binary="$app/Contents/MacOS/Lampa"
[[ -x "$binary" ]] || { echo "Application binary not found at $binary" >&2; exit 1; }

codesign --verify --deep --strict "$app" && echo 'codesign verify: ok'

"$binary" --remote-debugging-port="$port" --user-data-dir="$artifact/lampa-profile" \
  > "$artifact/lampa-app.log" 2>&1 &
app_pid=$!
echo "Lampa pid $app_pid"

node "$(cd "$(dirname "$0")" && pwd)/app-smoke.mjs" "$port" "$artifact/app-smoke.json" "$artifact/app-smoke.png"
probe=$?

if kill -0 "$app_pid" 2>/dev/null; then
  echo 'Lampa is still running after the probe'
  alive=true
else
  echo '::warning::Lampa exited before the probe finished'
  alive=false
fi

( kill "$app_pid" 2>/dev/null || true )
wait "$app_pid" 2>/dev/null
true

python3 - "$artifact" "$alive" "$probe" <<'PY'
import json
import pathlib
import sys

artifact = pathlib.Path(sys.argv[1])
alive = sys.argv[2] == 'true'
probe = int(sys.argv[3])
report_path = artifact / 'app-smoke.json'
report = json.loads(report_path.read_text()) if report_path.is_file() else {}
report['stayedAlive'] = alive
report_path.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
if probe != 0 or not report.get('pass'):
    raise SystemExit('The packaged Lampa.app did not render a document')
PY
