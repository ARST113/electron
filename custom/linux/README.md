# Linux x86_64 AC3/EAC3 build

User request: build Lampa Desktop RPMs using the existing VPS and GitHub Actions,
starting with the more common Intel/AMD x86_64 architecture. ARM64 is a later
separate build; a native RPM cannot serve both instruction sets.

The application stays on the existing fork's Electron 44.4.4. Its exact source
and Chromium 152.0.7977.130 revisions are pinned in `pins.json`. The native
checkout is `/build/lampa-ci/electron-44-linux`, separate from Android's checkout.
The runner is `lampa-linux-195-208-21-202` with label `lampa-linux`, registered
to ARST113/electron. Other runner services on this VPS are disabled at the
user's request. Their source trees and completed artifacts remain available.

Implementation sequence:

- Prepare the existing worker and register its dedicated Electron runner.
- Fetch pinned Electron/Chromium sources and apply upstream Electron patches.
- Enable FFmpeg AC3/EAC3 decoders and parser, Chromium codec-ID mapping and
  allowlist; regenerate the Linux x64 FFmpeg configuration and GN sources.
- Build a reusable Electron ZIP, then verify decoding of generated AC3/EAC3
  samples. Package Lampa into an x86_64 RPM with that exact runtime.
- Upload logs and artifacts; publish runtime and RPM assets to a GitHub Release.

Eight compiler jobs and disabled ThinLTO bound memory use on the 32 GiB worker.
The 16 GiB swap file was reactivated after reboot. Checkouts and compiler outputs
persist outside Actions' clean checkout. Version mismatches stop the build;
scripts never reset or delete an existing source checkout.

The CEF-specific patches from the Android build are not applied to Electron.
Only the software decoder mapping/configuration patch is shared. Passthrough is
disabled; these decoders produce PCM without a system Dolby decoder.

The RPM does not contain Windows subtitle executables. Optional FFmpeg subtitle
extraction/probing uses native `ffmpeg` and `ffprobe` from PATH on Linux. The
built-in browser audio decoders do not depend on these command-line tools.

The ARM64 workflow reuses the completed pinned source checkout on the x86_64 VPS
and builds a separate `out/Lampa_linux_arm64_ac3` directory. It verifies the
AArch64 ELF, FFmpeg decoder configuration and RPM metadata. The ARM64 Electron
binary is not executed on this x86_64 worker; a device or ARM64 host is needed
for a runtime playback check.

This first RPM is installed and updated manually from GitHub Releases. Linux
update-feed metadata is not published yet; the existing application updater
does not deliver these Linux releases automatically.

Progress and limitations: pipeline launch is not a successful compilation or
playback result. The workflow must finish its native build, media smoke test and
RPM checks before publishing a release. A real desktop/remote-control playback
check remains separate from headless decoder verification.
