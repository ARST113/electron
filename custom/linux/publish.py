#!/usr/bin/env python3
"""Publish immutable per-run runtime/RPM assets after all build checks pass."""
import hashlib
import json
import os
from pathlib import Path
import urllib.parse
import urllib.request
import zipfile

root = Path(__file__).resolve().parents[2]
cpu = os.environ.get('LINUX_TARGET_CPU', 'x64')
assert cpu in ('x64', 'arm64')
artifact = root / os.environ.get('LINUX_ARTIFACT_DIR', f'artifacts/linux')
repository = os.environ['GITHUB_REPOSITORY']
assert repository == 'ARST113/electron'
run = os.environ['GITHUB_RUN_NUMBER']
attempt = os.environ['GITHUB_RUN_ATTEMPT']
tag = f'v44.4.4-linux-{cpu}-ac3-eac3-r{run}a{attempt}'
manifest_path = artifact / f'electron-runtime-linux-{cpu}.json'
manifest = json.loads(manifest_path.read_text())
manifest.update(repository=repository, tag=tag,
                sourceRun=f'https://github.com/{repository}/actions/runs/{os.environ["GITHUB_RUN_ID"]}')
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
with zipfile.ZipFile(artifact / 'linux-build-info.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(artifact.rglob('*')):
        if file.is_file() and file.suffix in ('.json', '.patch', '.h', '.c', '.gn', '.gni', '.txt'):
            archive.write(file, file.relative_to(artifact))
assets = [artifact / manifest['asset'], manifest_path, artifact / 'codec-smoke.json',
          artifact / 'linux-build-info.zip', *artifact.glob('*.rpm')]
assert len(list(artifact.glob('*.rpm'))) == 1
checksums = []
for file in assets:
    with file.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    checksums.append(f'{digest}  {file.name}')
(artifact / 'SHASUMS256.txt').write_text('\n'.join(checksums) + '\n')
assets.append(artifact / 'SHASUMS256.txt')

headers = {'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
           'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28',
           'User-Agent': 'Lampa-Linux-Build'}

def api(path, data, method='POST'):
    request = urllib.request.Request('https://api.github.com/repos/' + repository + path,
                                     data=json.dumps(data).encode(), method=method,
                                     headers={**headers, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)

probe_text = ('The CI probe decoded generated AC3 and EAC3 samples into non-silent PCM using Electron. '
              if cpu == 'x64' else
              'The ARM64 archive and FFmpeg configuration were verified on the x86_64 builder; '
              'ARM64 runtime execution is not available on this host. ')
release = api('/releases', {
    'tag_name': tag, 'target_commitish': os.environ['GITHUB_SHA'],
    'name': f'Lampa Linux {cpu} RPM + Electron 44.4.4 AC3/EAC3',
    'draft': True, 'prerelease': True, 'make_latest': 'false',
    'body': (f'Linux {cpu} runtime with built-in FFmpeg AC3/EAC3 software decoders, plus Lampa Desktop RPM.\n\n'
            'The runtime ZIP can be reused for app-only rebuilds. Checksums and pinned source revisions are attached.\n\n' +
            probe_text +
            'Interactive playback and a physical remote remain separate device checks. '
            'Optional external subtitle extraction on Linux uses ffmpeg/ffprobe from PATH. '
            'Install and update this initial RPM manually; Linux auto-update metadata is not yet published.\n\n' + manifest['sourceRun']),
})
for file in assets:
    url = f'https://uploads.github.com/repos/{repository}/releases/{release["id"]}/assets?name=' + urllib.parse.quote(file.name)
    request = urllib.request.Request(url, data=file.read_bytes(), method='POST',
                                     headers={**headers, 'Content-Type': 'application/octet-stream'})
    with urllib.request.urlopen(request, timeout=600) as response:
        uploaded = json.load(response)
    assert uploaded['size'] == file.stat().st_size
api(f'/releases/{release["id"]}', {'draft': False, 'make_latest': 'false'}, 'PATCH')
print(release['html_url'])
with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
    summary.write(f'Linux {cpu} runtime and RPM: {release["html_url"]}\n')
