#!/usr/bin/env python3
"""Publish the statically verified arm64 runtime, the Lampa bundle and the checks.

Nothing in this pipeline can run the arm64 build: there is no Apple Silicon
machine in the fleet, so the release says so explicitly instead of implying that
playback was observed.
"""
import hashlib
import json
import os
from pathlib import Path
import urllib.parse
import urllib.request
import zipfile

root = Path(__file__).resolve().parents[2]
artifact = root / 'artifacts/macos-arm64'
repository = os.environ['GITHUB_REPOSITORY']
assert repository == 'ARST113/electron', repository
run = os.environ['GITHUB_RUN_NUMBER']
attempt = os.environ['GITHUB_RUN_ATTEMPT']
tag = f'v44.4.4-macos-arm64-ac3-eac3-r{run}a{attempt}'

manifest_path = artifact / 'electron-runtime-macos-arm64.json'
manifest = json.loads(manifest_path.read_text())
runtime_zip = artifact / manifest['asset']
images = sorted(artifact.glob('*.dmg'))
bundles = sorted(path for path in artifact.glob('*.zip') if path.name != manifest['asset'])
assert runtime_zip.is_file(), runtime_zip
assert len(images) == 1, images
assert len(bundles) == 1, bundles
assert manifest.get('arch') == 'arm64', manifest

manifest.update(
    repository=repository,
    tag=tag,
    sourceRun=f'https://github.com/{repository}/actions/runs/{os.environ["GITHUB_RUN_ID"]}',
    lampaRevision=(artifact / 'lampa-revision.txt').read_text().strip()
    if (artifact / 'lampa-revision.txt').is_file()
    else None,
)
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')

with zipfile.ZipFile(artifact / 'macos-arm64-build-info.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(artifact.rglob('*')):
        if file.is_file() and file.suffix in ('.json', '.txt', '.log'):
            archive.write(file, file.relative_to(artifact))

evidence = [
    manifest_path,
    artifact / 'static-checks.txt',
    artifact / 'subtitle-tools.txt',
    artifact / 'macos-arm64-build-info.zip',
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
    'User-Agent': 'Lampa-macOS-arm64-Build',
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
    'Apple Silicon (arm64) macOS runtime of Electron 44.4.4 built with '
    '`enable_platform_ac3_eac3_audio=true`, `proprietary_codecs=true` and '
    '`ffmpeg_branding="Chrome"`, plus the Lampa Desktop bundle that uses exactly this runtime.',
    f'Statically verified: thin arm64 Mach-O executable and framework, embedded Electron '
    f'{manifest.get("version")}, minimum macOS {manifest.get("minimumMacos")}, bundle layout and hashes.',
    'NOT executed: this fleet has no arm64 machine, so playback, torrents and subtitles remain '
    'unverified on this architecture. The Intel build carries the runtime evidence.',
    'The bundle is ad-hoc signed, not notarized: the first launch needs '
    'Right click -> Open or `xattr -dr com.apple.quarantine /Applications/Lampa.app`.',
    manifest['sourceRun'],
])

release = api(
    '/releases',
    {
        'tag_name': tag,
        'target_commitish': os.environ['GITHUB_SHA'],
        'name': 'Lampa macOS arm64 (Electron 44.4.4, AC3/EAC3)',
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
    summary.write(f'macOS arm64 runtime and Lampa bundle: {release["html_url"]}\n')
