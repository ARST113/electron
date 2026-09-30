#!/usr/bin/env python3
"""Publish the universal runtime, the Lampa bundle and the static evidence."""
import hashlib
import json
import os
from pathlib import Path
import urllib.parse
import urllib.request
import zipfile

root = Path(__file__).resolve().parents[2]
artifact = root / 'artifacts/macos-universal'
repository = os.environ['GITHUB_REPOSITORY']
assert repository == 'ARST113/electron', repository
run = os.environ['GITHUB_RUN_NUMBER']
attempt = os.environ['GITHUB_RUN_ATTEMPT']
tag = f'v44.4.4-macos-universal-ac3-eac3-r{run}a{attempt}'

manifest_path = artifact / 'electron-runtime-macos-universal.json'
manifest = json.loads(manifest_path.read_text())
runtime_zip = artifact / manifest['asset']
images = sorted(artifact.glob('*.dmg'))
bundles = sorted(path for path in artifact.glob('*.zip') if path.name != manifest['asset'])
assert runtime_zip.is_file(), runtime_zip
assert len(images) == 1, images
assert len(bundles) == 1, bundles
assert manifest.get('arch') == 'universal', manifest

manifest.update(
    repository=repository,
    tag=tag,
    sourceRun=f'https://github.com/{repository}/actions/runs/{os.environ["GITHUB_RUN_ID"]}',
    x64SourceRun=os.environ.get('X64_SOURCE_RUN') or None,
    arm64SourceRun=os.environ.get('ARM64_SOURCE_RUN') or None,
    lampaRevision=(artifact / 'lampa-revision.txt').read_text().strip()
    if (artifact / 'lampa-revision.txt').is_file()
    else None,
)
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')

with zipfile.ZipFile(artifact / 'macos-universal-build-info.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(artifact.rglob('*')):
        if file.is_file() and file.suffix in ('.json', '.txt', '.log'):
            archive.write(file, file.relative_to(artifact))

evidence = [
    manifest_path,
    artifact / 'static-checks.txt',
    artifact / 'lipo-report.txt',
    artifact / 'dmg-contents.txt',
    artifact / 'macos-universal-build-info.zip',
]
assets = [runtime_zip, *images, *bundles, *[path for path in evidence if path.is_file()]]

checksums = []
for file in assets:
    sha = hashlib.sha256()
    with file.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            sha.update(chunk)
    checksums.append(f'{sha.hexdigest()}  {file.name}')
(artifact / 'SHASUMS256.txt').write_text('\n'.join(checksums) + '\n')
assets.append(artifact / 'SHASUMS256.txt')

headers = {
    'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'Lampa-macOS-universal-Build',
}


def api(path, data, method='POST'):
    request = urllib.request.Request(
        'https://api.github.com/repos/' + repository + path,
        data=json.dumps(data).encode(),
        method=method,
        headers={**headers, 'Content-Type': 'application/json'},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)


body = '\n\n'.join([
    'Universal macOS runtime of Electron 44.4.4 (one bundle with both an Intel x86_64 and an '
    'Apple Silicon arm64 slice) built with `enable_platform_ac3_eac3_audio=true`, '
    '`proprietary_codecs=true` and `ffmpeg_branding="Chrome"`, plus the universal Lampa Desktop '
    'bundle. It starts natively on Intel Macs and on M-series Macs without Rosetta.',
    'Statically verified: both slices are present in the application binary, in Electron Framework '
    'and in the bundled ffmpeg; the disk image mounts and contains Lampa.app.',
    'What was actually observed: the x86_64 slice passed the full behavioural checks (AC3/EAC3 '
    'decoding with captured audio, a TorrServer torrent played with sound, subtitles extracted from '
    'a live stream, the application starting). The arm64 slice was never executed - there is no '
    'Apple Silicon machine in this fleet - so Apple Silicon playback is not confirmed.',
    'The bundle is ad-hoc signed, not notarized: the first launch needs '
    'Right click -> Open or `xattr -dr com.apple.quarantine /Applications/Lampa.app`.',
    manifest['sourceRun'],
])

release = api(
    '/releases',
    {
        'tag_name': tag,
        'target_commitish': os.environ['GITHUB_SHA'],
        'name': 'Lampa macOS universal (Electron 44.4.4, AC3/EAC3, x64 + arm64)',
        'draft': True,
        'prerelease': True,
        'make_latest': 'false',
        'body': body,
    },
)

for file in assets:
    url = (
        f'https://uploads.github.com/repos/{repository}/releases/{release["id"]}/assets?name='
        + urllib.parse.quote(file.name)
    )
    request = urllib.request.Request(
        url,
        data=file.read_bytes(),
        method='POST',
        headers={**headers, 'Content-Type': 'application/octet-stream'},
    )
    with urllib.request.urlopen(request, timeout=1800) as response:
        uploaded = json.load(response)
    assert uploaded['size'] == file.stat().st_size, file.name
    print('uploaded', file.name, uploaded['size'])

api(f'/releases/{release["id"]}', {'draft': False, 'make_latest': 'false'}, 'PATCH')
print(release['html_url'])
with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
    summary.write(f'macOS universal runtime and Lampa bundle: {release["html_url"]}\n')
