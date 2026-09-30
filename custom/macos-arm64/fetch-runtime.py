#!/usr/bin/env python3
"""Download the custom Electron macOS runtime artifact from an Actions run.

Usage: fetch-runtime.py <run-id-or-empty> <destination-dir>

With an empty run id the newest successful run of the macOS AC3/EAC3 workflow is
used, so the pipeline can also be started by hand long after the build.
"""
import io
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request
import zipfile

repository = os.environ['GITHUB_REPOSITORY']
token = os.environ['GH_TOKEN']
run_id, destination = sys.argv[1], pathlib.Path(sys.argv[2]).resolve()
pins = json.loads((pathlib.Path(__file__).resolve().parent / 'pins.json').read_text())
headers = {
    'Authorization': 'Bearer ' + token,
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'Lampa-macOS-Build',
}


class StripAuthOnRedirect(urllib.request.HTTPRedirectHandler):
    """GitHub redirects artifact downloads to pre-signed blob storage.

    Forwarding the bearer token there makes the storage backend answer 401, so the
    Authorization header is dropped as soon as the redirect leaves api.github.com.
    """

    def redirect_request(self, req, fp, code, msg, response_headers, new_url):
        redirected = super().redirect_request(req, fp, code, msg, response_headers, new_url)
        if redirected is not None and 'api.github.com' not in new_url:
            redirected.headers.pop('Authorization', None)
            redirected.headers.pop('authorization', None)
            redirected.unredirected_hdrs.pop('Authorization', None)
        return redirected


opener = urllib.request.build_opener(StripAuthOnRedirect)


def api(url):
    request = urllib.request.Request(url, headers=headers)
    with opener.open(request, timeout=120) as response:
        return json.load(response)


if not run_id:
    runs = api(
        f'https://api.github.com/repos/{repository}/actions/workflows/'
        f'{pins["runtime_workflow"]}/runs?status=success&per_page=1'
    )
    entries = runs.get('workflow_runs', [])
    assert entries, 'no successful runtime build run found'
    run_id = entries[0]['id']
    print(f'Using newest successful runtime run {run_id} ({entries[0]["head_sha"][:12]})')

artifacts = api(f'https://api.github.com/repos/{repository}/actions/runs/{run_id}/artifacts')['artifacts']
matching = [entry for entry in artifacts if entry['name'] == pins['runtime_artifact']]
assert matching, f'run {run_id} has no {pins["runtime_artifact"]} artifact: {[a["name"] for a in artifacts]}'
artifact = matching[0]
assert not artifact['expired'], 'runtime artifact has expired; rebuild or re-upload it'

request = urllib.request.Request(artifact['archive_download_url'], headers=headers)
for attempt in range(3):
    try:
        with opener.open(request, timeout=1800) as response:
            payload = response.read()
        break
    except urllib.error.HTTPError as error:
        if attempt == 2:
            raise
        print(f'artifact download attempt {attempt + 1} failed with {error}, retrying')
        time.sleep(5)
assert payload, 'artifact download returned no data'
destination.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(io.BytesIO(payload)) as package:
    package.extractall(destination)
(run_id_path := destination / 'runtime-run.txt').write_text(f'{run_id}\n')
print(f'Run id {run_id}, artifact {artifact["name"]}, size {artifact["size_in_bytes"]} bytes -> {destination}')
print(run_id_path)
