# macOS x86_64 AC3/EAC3 runtime and Lampa bundle

User request: after the custom Electron build finishes, check the macOS version of
Lampa and really play a torrent with sound — driven by GitHub Actions instead of
manual work on the VM.

The macOS analogue of `custom/linux/` (branch `linux/ac3-eac3`) lives here. It does
not compile Electron again: it consumes the artifact of the `Custom Electron macOS
x64 AC3-EAC3` workflow (`custom-macos-ac3-eac3.yml`, runner labels
`[self-hosted, macOS, X64]`), verifies it, packages Lampa with exactly that runtime,
plays a real torrent through TorrServer and publishes a draft GitHub Release.

Pipeline (`custom-macos-lampa-ac3-eac3.yml`, branch `main`):

1. `fetch-runtime.py` downloads the Electron artifact of the triggering run (or of
   `runtime_run_id`, or of the newest successful runtime run).
2. `runtime-manifest.py` asserts the archive is an Electron 44.4.4 x86_64
   distribution and records hashes of the archive, the executable and
   `Electron Framework`.
3. `verify.sh` probes decoding twice:
   - `smoke.cjs` — `decodeAudioData` into an `OfflineAudioContext`. This uses
     Chromium's FFmpeg decoders filtered by `media::GetAllowedAudioDecoders()`,
     which is the path the Linux build had to patch.
   - `playback.cjs` — a `<video>` element playing the fixture, tapped with Web Audio
     and written to `playback-*.wav`. This is the platform (AudioToolbox) decoder
     path that Lampa uses during real playback.
   The verdict records which path works. The step fails only when a codec cannot be
   played at all, so a platform-only runtime still counts as usable for Lampa while
   being reported honestly.
4. `package.sh` checks out the pinned `ARST113/lampa-desktop`, runs its unit tests,
   builds `Lampa.app` with electron-builder using `electronDist` = the verified
   runtime, asserts the packaged `Electron Framework` is byte-identical to the
   runtime's, ad-hoc signs the bundle and produces a `.dmg` and a `.zip`.
5. `torrent-smoke.sh` starts the same TorrServer build that Lampa downloads at
   runtime (`YouROK/TorrServer`, asset `TorrServer-darwin-amd64`), feeds it a torrent
   with an AC3 5.1 track, waits for the pieces, plays the TorrServer stream in the
   custom runtime and captures 30 s of decoded audio into `torrent-audio.wav`.
   Without a `torrent_magnet` input the committed `fixtures/torrent-sample.mkv`
   (H.264 + AC3 5.1) is seeded by `torrent-seed.mjs` through a private local tracker,
   so a real BitTorrent exchange always happens and no public swarm is required.
6. `publish.py` creates a draft release with the runtime, the `.dmg`, the `.zip`,
   the WAV evidence, the verdicts and `SHASUMS256.txt`.

## Evidence to look at after a run

- `codec-verdict.json` — which decoding path works for ac3/eac3.
- `playback-ac3.wav`, `playback-eac3.wav` — decoded fixture audio, listen to them.
- `torrent-playback.json` — stream URL, decoded audio bytes, RMS, captured seconds.
- `torrent-audio.wav` — the sound of the torrent playback itself.
- `electron-runtime-macos-x64.json` — pinned revisions, hashes, decoding mode.

## Limits and open points

- The bundle is ad-hoc signed, never notarized: an Apple Developer ID certificate is
  required for a clean Gatekeeper experience. First launch on a Mac needs
  `xattr -dr com.apple.quarantine /Applications/Lampa.app` or Right click → Open.
- The VM has no usable sound card, therefore "sound" is proven by captured PCM in a
  WAV file rather than by speakers. The same capture works on real hardware.
- One self-hosted runner serves both the Electron build and this pipeline, so a
  build run and a verification run never overlap; the concurrency groups also keep
  each pipeline single-flight.
- Visible source revisions and hashes are pinned in `pins.json`; a runtime whose
  version or architecture does not match is rejected before packaging.
- The real-torrent step is the only one that touches the public swarm; a
  `torrent_magnet` input can point it at real content instead of the local sample.
