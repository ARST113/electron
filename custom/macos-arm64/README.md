# macOS arm64 (Apple Silicon) runtime and Lampa bundle

The Intel pipeline lives in `custom/macos/`; this is its Apple Silicon twin.

How the build differs from the Intel one:

- Chromium cross-compiles to arm64 **from an x86_64 macOS host**, so there is no
  second source tree and no second two-hour sync. The arm64 workflow derives a
  profile (`evm.ac3-macos-arm64.json`) from the Intel profile, keeps the same
  `root`, and only adds `out/Release-arm64` with `target_cpu="arm64"`.
- Everything else — GN arguments, FFmpeg first, `electron:electron_dist_zip` — is
  the same.

What can and cannot be verified:

- **Can**: thin arm64 Mach-O for the executable and `Electron Framework`, the
  embedded Electron version, the minimum macOS version, the bundle layout, the
  hashes, and that the packaged `Lampa.app` uses exactly the verified framework
  and carries arm64 `ffmpeg`/`ffprobe` for subtitles. The `.dmg` is mounted and
  listed, which proves the image is valid.
- **Cannot**: run anything. There is no Apple Silicon machine in the fleet and no
  way to emulate arm64 on x86_64, so playback, torrents and subtitle rendering on
  arm64 stay unverified until someone runs the bundle on a Mac with an M-series
  chip. The release body says this explicitly.

Pipeline (`custom-macos-arm64-lampa-ac3-eac3.yml`, branch `main`):

1. `fetch-runtime.py` downloads the artifact of the arm64 build run.
2. `static-verify.py` performs the static checks above and writes
   `electron-runtime-macos-arm64.json`.
3. `package.sh` builds `Lampa.app` with electron-builder `--mac --arm64`, bundles
   arm64 `ffmpeg`/`ffprobe` for subtitles, ad-hoc signs the bundle, and produces a
   `.dmg` and `.zip`.
4. The workflow records `file`/`codesign`/`hdiutil` output into
   `static-checks.txt`, mounts the `.dmg` and lists its contents.
5. `publish.py` creates a release with the runtime, the bundle and the static
   evidence.
