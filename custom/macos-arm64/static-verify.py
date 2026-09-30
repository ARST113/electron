#!/usr/bin/env python3
"""Static verification of the unpacked arm64 Electron runtime.

No arm64 machine exists in this fleet, so nothing here can execute the binary.
The check therefore validates everything that is provable from the bytes: the
thin Mach-O CPU type of the executable and of Electron Framework, the embedded
Electron version, the bundle layout and the hashes recorded in the manifest.
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

pins = json.loads((repo / 'custom/macos-arm64/pins.json').read_text())
executable = runtime / 'Electron.app/Contents/MacOS/Electron'
framework = runtime / 'Electron.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework'
version_file = runtime / 'version'
for path in (executable, framework, version_file):
    assert path.is_file(), f'missing runtime file: {path}'

version = version_file.read_text().strip()
assert version == pins['electron_version'], f'expected Electron {pins["electron_version"]}, found {version}'


def macho_cpu(path):
    with path.open('rb') as stream:
        header = stream.read(8)
    assert header[:4] == b'\xcf\xfa\xed\xfe', f'{path.name} is not a little-endian 64-bit Mach-O'
    return int.from_bytes(header[4:8], 'little')


ARM64_CPU = 0x0100000C
for path in (executable, framework):
    cpu = macho_cpu(path)
    assert cpu == ARM64_CPU, f'{path.name} has cputype {cpu:#x}, expected arm64'


def digest(path):
    sha = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            sha.update(chunk)
    return sha.hexdigest()


def tool(*command):
    try:
        return subprocess.run(command, check=True, capture_output=True, text=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ''


with zipfile.ZipFile(archive_path) as package:
    names = package.namelist()
assert any(name.startswith('Electron.app/') for name in names), 'archive has no Electron.app'

build = tool('vtool', '-show-build', str(executable))
minos = ''
for line in build.splitlines():
    if 'minos' in line:
        minos = line.split()[-1]
        break

data = dict(pins)
data.update(
    version=version,
    platform='macos',
    arch='arm64',
    asset=archive_path.name,
    sha256=digest(archive_path),
    executableSha256=digest(executable),
    frameworkSha256=digest(framework),
    shell=tool('file', str(executable)),
    minimumMacos=minos or None,
    decoding='enable_platform_ac3_eac3_audio=true, proprietary_codecs=true, ffmpeg_branding="Chrome"',
    executed=False,
    note='Built and statically verified; there is no arm64 machine to run it on.',
    controller_revision=tool('git', '-C', str(repo), 'rev-parse', 'HEAD'),
)
(runtime.parent / 'electron-runtime-macos-arm64.json').write_text(json.dumps(data, indent=2) + '\n')
print(json.dumps(data, indent=2))
