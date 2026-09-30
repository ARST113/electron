#!/usr/bin/env python3
"""Describe the merged universal runtime: both slices, hashes and provenance."""
import hashlib
import json
import pathlib
import subprocess
import sys

runtime = pathlib.Path(sys.argv[1]).resolve()
repo = pathlib.Path(sys.argv[2]).resolve()
archive = pathlib.Path(sys.argv[3]).resolve()

pins = json.loads((repo / 'custom/macos-universal/pins.json').read_text())
executable = runtime / 'Electron.app/Contents/MacOS/Electron'
framework = runtime / 'Electron.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework'
version_file = runtime / 'version'
for path in (executable, framework, version_file):
    assert path.is_file(), f'missing runtime file: {path}'
version = version_file.read_text().strip()
assert version == pins['electron_version'], version


def digest(path):
    sha = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            sha.update(chunk)
    return sha.hexdigest()


slices = {}
for name, path in (('executable', executable), ('framework', framework)):
    info = subprocess.run(['lipo', '-info', str(path)], check=True, capture_output=True, text=True).stdout.strip()
    assert 'x86_64' in info and 'arm64' in info, info
    slices[name] = info

data = dict(pins)
data.update(
    version=version,
    platform='macos',
    arch='universal',
    asset=archive.name,
    sha256=digest(archive),
    executableSha256=digest(executable),
    frameworkSha256=digest(framework),
    slices=slices,
    decoding='enable_platform_ac3_eac3_audio=true, proprietary_codecs=true, ffmpeg_branding="Chrome"',
    controller_revision=subprocess.run(
        ['git', '-C', str(repo), 'rev-parse', 'HEAD'], check=True, capture_output=True, text=True
    ).stdout.strip(),
    executed={'x86_64': True, 'arm64': False},
    note='The x86_64 slice is behaviourally verified by the Intel pipeline (sound, torrent, '
         'subtitles). The arm64 slice is statically verified only: no Apple Silicon machine '
         'is available to run it.',
)
(runtime.parent / 'electron-runtime-macos-universal.json').write_text(json.dumps(data, indent=2) + '\n')
print(json.dumps(data, indent=2))
