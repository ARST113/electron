#!/usr/bin/env python3
"""Describe the unpacked macOS Electron runtime and record its hashes.

Fails when the archive is not a 44.4.4 x86_64 Electron distribution, so a stale
or wrong-architecture artifact can never reach packaging or a release.
"""
import hashlib
import json
import pathlib
import subprocess
import sys
import zipfile

runtime = pathlib.Path(sys.argv[1]).resolve()
repo = pathlib.Path(sys.argv[2]).resolve()
archive_path = pathlib.Path(sys.argv[3]).resolve()

pins = json.loads((repo / 'custom/macos/pins.json').read_text())
executable = runtime / 'Electron.app/Contents/MacOS/Electron'
framework = runtime / 'Electron.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework'
version_file = runtime / 'version'
for path in (executable, framework, version_file):
    assert path.is_file(), f'missing runtime file: {path}'

version = version_file.read_text().strip()
assert version == pins['electron_version'], f'expected Electron {pins["electron_version"]}, found {version}'

with executable.open('rb') as stream:
    header = stream.read(8)
assert header[:4] == b'\xcf\xfa\xed\xfe', 'expected a little-endian 64-bit Mach-O executable'
cpu = int.from_bytes(header[4:8], 'little')
assert cpu == 0x01000007, f'expected x86_64 Mach-O, found cputype {cpu:#x}'

architecture = subprocess.run(['file', str(executable)], check=True, capture_output=True, text=True).stdout.strip()


def digest(path):
    sha = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            sha.update(chunk)
    return sha.hexdigest()


archive_hash = digest(archive_path)

with zipfile.ZipFile(archive_path) as package:
    names = package.namelist()
assert any(name.startswith('Electron.app/') for name in names), 'archive has no Electron.app'

data = dict(pins)
data.update(
    version=version,
    platform='macos',
    arch='x64',
    asset=archive_path.name,
    sha256=archive_hash,
    executableSha256=digest(executable),
    frameworkSha256=digest(framework),
    shell=architecture,
    decoding='enable_platform_ac3_eac3_audio=true, proprietary_codecs=true, ffmpeg_branding="Chrome"',
    controller_revision=subprocess.run(
        ['git', '-C', str(repo), 'rev-parse', 'HEAD'], check=True, capture_output=True, text=True
    ).stdout.strip(),
)
(runtime.parent / 'electron-runtime-macos-x64.json').write_text(json.dumps(data, indent=2) + '\n')
print(json.dumps(data, indent=2))
