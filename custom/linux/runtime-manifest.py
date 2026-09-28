#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

artifact, repo = map(Path, sys.argv[1:3])
cpu = sys.argv[3] if len(sys.argv) > 3 else 'x64'
assert cpu in ('x64', 'arm64')
name = f'electron-v44.4.4-linux-{cpu}-ac3-eac3.zip'
archive = artifact / name
machine = {'x64': b'\x3e\x00', 'arm64': b'\xb7\x00'}[cpu]
with zipfile.ZipFile(archive) as package:
    assert {'electron', 'libffmpeg.so', 'version'}.issubset(package.namelist())
    version = package.read('version').decode().strip()
    assert version == '44.4.4', version
    with package.open('electron') as executable:
        header = executable.read(20)
    assert header[:6] == b'\x7fELF\x02\x01' and header[18:20] == machine, f'Expected Linux {cpu} ELF'
    with package.open('libffmpeg.so') as library:
        ffmpeg_hash = hashlib.file_digest(library, 'sha256').hexdigest()
with archive.open('rb') as source:
    archive_hash = hashlib.file_digest(source, 'sha256').hexdigest()
data = json.loads((repo / 'custom/linux/pins.json').read_text())
data.update(version=version, platform='linux', arch=cpu, asset=name,
            sha256=archive_hash, ffmpegSha256=ffmpeg_hash,
            decoding=('Built-in FFmpeg AC3/EAC3 software decoding to PCM'
                      if cpu == 'x64' else
                      'Built-in FFmpeg AC3/EAC3 software decoding; ARM64 runtime probe is not run on x86_64 CI'),
            controller_revision=subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip())
(artifact / f'electron-runtime-linux-{cpu}.json').write_text(json.dumps(data, indent=2) + '\n')
(artifact / 'SHASUMS256.txt').write_text(f'{archive_hash}  {name}\n')
print(json.dumps(data, indent=2))
