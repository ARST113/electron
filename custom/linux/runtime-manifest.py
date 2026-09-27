#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

artifact, repo = map(Path, sys.argv[1:])
name = 'electron-v44.4.4-linux-x64-ac3-eac3.zip'
archive = artifact / name
with zipfile.ZipFile(archive) as package:
    assert {'electron', 'libffmpeg.so', 'version'}.issubset(package.namelist())
    version = package.read('version').decode().strip()
    assert version == '44.4.4', version
    with package.open('electron') as executable:
        header = executable.read(20)
    assert header[:6] == b'\x7fELF\x02\x01' and header[18:20] == b'\x3e\x00', 'Expected Linux x86_64 ELF'
    with package.open('libffmpeg.so') as library:
        ffmpeg_hash = hashlib.file_digest(library, 'sha256').hexdigest()
with archive.open('rb') as source:
    archive_hash = hashlib.file_digest(source, 'sha256').hexdigest()
data = json.loads((repo / 'custom/linux/pins.json').read_text())
data.update(version=version, platform='linux', arch='x64', asset=name,
            sha256=archive_hash, ffmpegSha256=ffmpeg_hash,
            decoding='Built-in FFmpeg AC3/EAC3 software decoding to PCM',
            controller_revision=subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip())
(artifact / 'electron-runtime-linux-x64.json').write_text(json.dumps(data, indent=2) + '\n')
(artifact / 'SHASUMS256.txt').write_text(f'{archive_hash}  {name}\n')
print(json.dumps(data, indent=2))
