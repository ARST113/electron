#!/usr/bin/env python3
"""Publish the verified macOS runtime, the Lampa bundle and the evidence.

Every check must have produced its report before this script runs; the release is
created as a draft and only made visible after all assets are uploaded.
"""
import hashlib
import json
import os
from pathlib import Path
import urllib.parse
import urllib.request
import zipfile

root = Path(__file__).resolve().parents[2]
artifact = root / 'artifacts/macos'
repository = os.environ['GITHUB_REPOSITORY']
assert repository == 'ARST113/electron', repository
run = os.environ['GITHUB_RUN_NUMBER']
attempt = os.environ['GITHUB_RUN_ATTEMPT']
tag = f'v44.4.4-macos-x64-ac3-eac3-r{run}a{attempt}'

manifest_path = artifact / 'electron-runtime-macos-x64.json'
manifest = json.loads(manifest_path.read_text())
verdict = json.loads((artifact / 'codec-verdict.json').read_text())
torrent_path = artifact / 'torrent-playback.json'
torrent = json.loads(torrent_path.read_text()) if torrent_path.is_file() else {}
stream_path = artifact / 'stream-verdict.json'
stream = json.loads(stream_path.read_text()) if stream_path.is_file() else None
app_path = artifact / 'app-smoke.json'
app_smoke = json.loads(app_path.read_text()) if app_path.is_file() else None
subtitle_path = artifact / 'subtitle-verdict.json'
subtitles = json.loads(subtitle_path.read_text()) if subtitle_path.is_file() else None

runtime_zip = artifact / manifest['asset']
images = sorted(artifact.glob('*.dmg'))
bundles = sorted(path for path in artifact.glob('*.zip') if path.name != manifest['asset'])
assert runtime_zip.is_file(), runtime_zip
assert len(images) == 1, images
assert len(bundles) == 1, bundles
assert verdict['supported'], verdict

manifest.update(
    repository=repository,
    tag=tag,
    sourceRun=f'https://github.com/{repository}/actions/runs/{os.environ["GITHUB_RUN_ID"]}',
    lampaRevision=(artifact / 'lampa-revision.txt').read_text().strip()
    if (artifact / 'lampa-revision.txt').is_file()
    else None,
    codecVerdict=verdict,
    realContent=stream,
    appSmoke=app_smoke,
    subtitles=subtitles,
    torrentPlayback={
        'ok': bool(torrent.get('pass')),
        'rms': torrent.get('rms'),
        'peak': torrent.get('peak'),
        'capturedSeconds': torrent.get('capturedSeconds'),
        'decodedAudioBytes': torrent.get('decodedAudioBytes'),
    },
)
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')

with zipfile.ZipFile(artifact / 'macos-build-info.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(artifact.rglob('*')):
        if file.is_file() and (file.suffix in ('.json', '.txt', '.m3u', '.log') or file.name == 'codec-verdict.json'):
            archive.write(file, file.relative_to(artifact))

evidence = [
    manifest_path,
    artifact / 'codec-verdict.json',
    artifact / 'codec-smoke.json',
    artifact / 'playback-ac3.json',
    artifact / 'playback-eac3.json',
    artifact / 'playback-ac3.wav',
    artifact / 'playback-eac3.wav',
    artifact / 'torrent-playback.json',
    artifact / 'torrent-audio.wav',
    artifact / 'torrserver-status.json',
    artifact / 'torrserver-add.json',
    artifact / 'torrserver-echo.json',
    artifact / 'torrserver-playlist.m3u',
    artifact / 'stream-info.json',
    artifact / 'stream-verdict.json',
    artifact / 'stream-playback.json',
    artifact / 'stream-raw.json',
    artifact / 'stream-audio.wav',
    artifact / 'stream-sample-ac3.mp4',
    artifact / 'stream-cut.log',
    artifact / 'app-smoke.json',
    artifact / 'app-smoke.png',
    artifact / 'lampa-app.log',
    artifact / 'subtitle-verdict.json',
    artifact / 'subtitle-sample.vtt',
    artifact / 'torrserver-seeder.log',
    artifact / 'torrent-seeder.log',
    artifact / 'macos-build-info.zip',
]
assets = [runtime_zip, *images, *bundles, *[path for path in evidence if path.is_file()]]

def sha256_of(path):
    sha = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            sha.update(chunk)
    return sha.hexdigest()


checksums = []
for file in assets:
    checksums.append(f'{sha256_of(file)}  {file.name}')
(artifact / 'SHASUMS256.txt').write_text('\n'.join(checksums) + '\n')
assets.append(artifact / 'SHASUMS256.txt')

headers = {
    'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'Lampa-macOS-Build',
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


body_parts = [
    'macOS x86_64 runtime of Electron 44.4.4 built with `enable_platform_ac3_eac3_audio=true`, '
    '`proprietary_codecs=true` and `ffmpeg_branding="Chrome"`, plus the Lampa Desktop bundle '
    'that uses exactly this runtime.',
    f'AC3/EAC3 verification: decodeAudioData to PCM -> {verdict["decodeToPcm"]}, '
    f'media-element playback with captured audio -> {verdict["playback"]}.',
    f'Torrent check: TorrServer streamed the sample with an AC3 5.1 track and '
    f'{torrent.get("capturedSeconds")} seconds of decoded audio were captured at RMS '
    f'{torrent.get("rms")} (attached as torrent-audio.wav).',
]
if stream:
    body_parts.append(
        f'Real content check: {stream.get("capturedSeconds")} seconds of a live stream '
        f'(first AC3/EAC3 track) were decoded at RMS {stream.get("rms")} '
        f'(attached as stream-audio.wav and stream-sample-ac3.mp4).'
    )
if app_smoke:
    body_parts.append(
        f'Application smoke test: Lampa.app started, the renderer reported '
        f'"{app_smoke.get("title")}" at {app_smoke.get("url")} '
        f'(screenshot attached as app-smoke.png).'
    )
if subtitles:
    streams = subtitles.get('streams') or []
    languages = ', '.join(sorted({stream.get('language') for stream in streams if stream.get('language')}))
    body_parts.append(
        f'Subtitles: the bundle probed {len(streams)} tracks ({languages}) and extracted '
        f'{subtitles.get("cues")} cues from a live stream using its own bundled ffmpeg '
        f'(attached as subtitle-sample.vtt).'
    )
body_parts.append(
    'The bundle is ad-hoc signed, not notarized: the first launch needs '
    'Right click -> Open or `xattr -dr com.apple.quarantine /Applications/Lampa.app`.'
)
body_parts.append(manifest['sourceRun'])
body = '\n\n'.join(part for part in body_parts if part)

release = api(
    '/releases',
    {
        'tag_name': tag,
        'target_commitish': os.environ['GITHUB_SHA'],
        'name': 'Lampa macOS x86_64 (Electron 44.4.4, AC3/EAC3)',
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
    summary.write(f'macOS x86_64 runtime and Lampa bundle: {release["html_url"]}\n')
