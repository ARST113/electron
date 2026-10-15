# HDR10, HLG and Dolby Vision diagnostics for pinned Electron 44.4.4 runtimes

Workflow: `.github/workflows/hdr-dv-existing-electron.yml`.

The test does not rebuild Chromium. It downloads existing custom Electron binaries published in `ARST113/electron` for Windows x64, Linux x64/ARM64, macOS x64/ARM64.

The Ubuntu fixture job creates short, original SDR H.264, HDR10 HEVC 10-bit BT.2020/PQ, and HLG HEVC 10-bit BT.2020/HLG clips. HDR10 is tested as MP4 and Matroska. FFprobe validates source metadata.

Electron opens all four videos through HTMLMediaElement, records actual playback position and video frame counts, and probes HEVC and Dolby Vision API capabilities (MediaCapabilities, MediaSource and WebCodecs).

**Interpretation:** `decoded-frames` confirms video decoding took place in the virtual display. It **does not confirm** that the physical output is HDR or that the BT.2020/PQ signal survived the display path. Profile 7 requires a genuine BL+EL+RPU fixture and compatible hardware. The report explicitly marks DV Profile 7 and real HDR screen output as unverified rather than inventing a pass.

Reports and Chromium logs are published as per-architecture workflow artifacts. A successful job indicates diagnostics finished; codec playback status is found in the JSON report.

Triggered for the experiment branch by the next push after adding the workflow; no changes to stable Electron runtime or application packages.
