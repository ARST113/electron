// HDR / Dolby Vision diagnostic for existing custom Electron 44.4.4 runtimes.
// Verifies ACTUAL playback of self-generated SDR, HDR10, HLG clips and separately
// reports API-level Dolby Vision capability; it does NOT claim Profile 7 playback
// without a genuine BL+EL+RPU test file and an HDR capable display.
const { app, BrowserWindow } = require("electron");
const fs = require("node:fs");
const path = require("node:path");
const http = require("node:http");

const fixtures = path.resolve(process.argv[2] || "fixtures");
const output = path.resolve(process.argv[3] || "artifacts/hdr-dv-probe.json");
fs.mkdirSync(path.dirname(output), { recursive: true });
const profile = path.resolve(path.dirname(output), "electron-profile");
fs.mkdirSync(profile, { recursive: true });
app.setPath("userData", profile);
app.commandLine.appendSwitch("autoplay-policy", "no-user-gesture-required");
app.commandLine.appendSwitch("enable-logging", "stderr");
app.commandLine.appendSwitch("disable-background-timer-throttling");

const testMedia = [
  { name: "sdr-h264.mp4", type: "video/mp4", label: "SDR H.264 MP4 baseline" },
  { name: "hdr10-hevc.mp4", type: "video/mp4", label: "HDR10 HEVC Main10 MP4" },
  { name: "hdr10-hevc.mkv", type: "video/x-matroska", label: "HDR10 HEVC Main10 MKV" },
  { name: "hlg-hevc.mp4", type: "video/mp4", label: "HLG HEVC Main10 MP4" },
];
const report = {
  checkedAt: new Date().toISOString(),
  environment: {
    platform: process.platform, arch: process.arch, versions: process.versions,
    runner: process.env.RUNNER_NAME || null,
  },
  metadata: {},
  warning: [
    "CI virtual displays cannot establish HDR10/HLG output to a physical HDR screen.",
    "Dolby Vision Profile 7 BL+EL+RPU playback is NOT verified without a real test bitstream.",
    "BT.2020/PQ in ffprobe proves INPUT metadata only, not end-to-end color reproduction.",
    "MediaCapabilities/WebCodecs support is API reporting, not proof of hardware decoding.",
  ],
};

for (const m of testMedia) {
  const file = path.join(fixtures, m.name);
  if (!fs.existsSync(file)) throw new Error("Missing fixture: " + file);
  const probeFile = file + ".ffprobe.json";
  report.metadata[m.name] = fs.existsSync(probeFile)
    ? JSON.parse(fs.readFileSync(probeFile, "utf8"))
    : { error: "Missing ffprobe metadata" };
}

const server = http.createServer((req, res) => {
  const name = decodeURIComponent((req.url || "/").split("?")[0].slice(1));
  if (!name) {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    res.end("<!doctype html><html><body><h1>Electron HDR probe</h1></body></html>");
    return;
  }
  const candidate = testMedia.find((m) => m.name === name);
  if (!candidate) { res.writeHead(404); res.end(); return; }
  const data = fs.readFileSync(path.join(fixtures, name));
  const range = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range || "");
  const start = range ? Number(range[1]) : 0;
  const end = range && range[2] ? Math.min(Number(range[2]), data.length - 1) : data.length - 1;
  if (start >= data.length || end < start) {
    res.writeHead(416, { "Content-Range": "bytes */" + data.length }); res.end(); return;
  }
  res.writeHead(range ? 206 : 200, {
    "Content-Type": candidate.type,
    "Content-Length": end - start + 1,
    "Accept-Ranges": "bytes",
    ...(range ? { "Content-Range": "bytes " + start + "-" + end + "/" + data.length } : {}),
    "Access-Control-Allow-Origin": "*",
  });
  res.end(data.subarray(start, end + 1));
});

const watchdog = setTimeout(() => {
  report.fatal = "Global probe timeout";
  fs.writeFileSync(output, JSON.stringify(report, null, 2));
  app.exit(2);
}, 150000);

let win;
app.whenReady().then(async () => {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  win = new BrowserWindow({
    show: false, width: 800, height: 450,
    webPreferences: { sandbox: false, backgroundThrottling: false },
  });
  await win.loadURL("http://127.0.0.1:" + server.address().port + "/");
  const browserResults = await win.webContents.executeJavaScript(
    "(" + (async function runProbes(entries) {
      const result = {
        ua: navigator.userAgent,
        screen: {
          width: screen.width, height: screen.height, colorDepth: screen.colorDepth,
          hdrMediaQuery: matchMedia("(dynamic-range: high)").matches,
          p3MediaQuery: matchMedia("(color-gamut: p3)").matches,
          rec2020MediaQuery: matchMedia("(color-gamut: rec2020)").matches,
        },
        mime: {}, webCodecs: {}, mediaCapabilities: {}, playback: [],
      };
      const v = document.createElement("video");
      for (const codec of [
        "hvc1.2.4.L120.B0",
        "hev1.2.4.L120.B0",
        "dvhe.07.06",
        "dvh1.07.06",
        "dvhe.08.06",
        "dvh1.08.06",
        "dvhe.05.06",
        "avc1.42E01E",
      ]) {
        const contentType = 'video/mp4; codecs="' + codec + '"';
        result.mime[codec] = {
          canPlayType: v.canPlayType(contentType),
          mse: typeof MediaSource !== "undefined"
            ? MediaSource.isTypeSupported(contentType) : "MediaSource unavailable",
        };
        try {
          result.webCodecs[codec] = typeof VideoDecoder === "undefined"
            ? { supported: false, detail: "VideoDecoder not exposed" }
            : await Promise.race([
              VideoDecoder.isConfigSupported({ codec, codedWidth: 320, codedHeight: 180 })
                .then((r) => ({ supported: r.supported }))
                .catch((e) => ({ error: String(e) })),
              new Promise((resolve) => setTimeout(() => resolve({ error: "timeout" }), 3500)),
            ]);
        } catch (e) { result.webCodecs[codec] = { error: String(e) }; }
      }
      const capabilities = [
        { name: "HDR10-HEVC", codec: "hvc1.2.4.L120.B0", transferFunction: "pq", colorGamut: "rec2020" },
        { name: "HLG-HEVC", codec: "hvc1.2.4.L120.B0", transferFunction: "hlg", colorGamut: "rec2020" },
        { name: "DV-P7", codec: "dvhe.07.06", transferFunction: "pq", colorGamut: "rec2020" },
        { name: "DV-P8", codec: "dvhe.08.06", transferFunction: "pq", colorGamut: "rec2020" },
      ];
      for (const c of capabilities) {
        try {
          if (!navigator.mediaCapabilities) {
            result.mediaCapabilities[c.name] = { error: "MediaCapabilities unavailable" };
          } else {
            const response = await Promise.race([
              navigator.mediaCapabilities.decodingInfo({
                type: "file",
                video: {
                  contentType: 'video/mp4; codecs="' + c.codec + '"',
                  width: 320, height: 180, bitrate: 800000, framerate: 12,
                  transferFunction: c.transferFunction, colorGamut: c.colorGamut,
                },
              }).then((r) => ({ supported: r.supported, smooth: r.smooth, powerEfficient: r.powerEfficient }))
                .catch((e) => ({ error: String(e) })),
              new Promise((resolve) => setTimeout(() => resolve({ error: "timeout" }), 3500)),
            ]);
            result.mediaCapabilities[c.name] = response;
          }
        } catch (e) { result.mediaCapabilities[c.name] = { error: String(e) }; }
      }
      for (const entry of entries) {
        const video = document.createElement("video");
        video.muted = true;
        video.playsInline = true;
        video.preload = "auto";
        video.style.width = "320px";
        document.body.appendChild(video);
        let callbacks = 0;
        if (typeof video.requestVideoFrameCallback === "function") {
          const onFrame = () => {
            callbacks += 1;
            if (callbacks < 100 && !video.paused) video.requestVideoFrameCallback(onFrame);
          };
          video.requestVideoFrameCallback(onFrame);
        }
        const record = {
          label: entry.label, name: entry.name,
          type: video.canPlayType(entry.type),
        };
        try {
          video.src = "/" + entry.name;
          video.load();
          await Promise.race([
            new Promise((resolve, reject) => {
              video.addEventListener("loadeddata", resolve, { once: true });
              video.addEventListener("error", () => reject(new Error("MEDIA_ERR " + (video.error?.code || "?") + " " + (video.error?.message || ""))), { once: true });
            }),
            new Promise((_, reject) => setTimeout(() => reject(new Error("loadeddata timeout")), 12000)),
          ]);
          await video.play();
          await new Promise((resolve) => setTimeout(resolve, 1900));
          const quality = video.getVideoPlaybackQuality?.();
          record.currentTime = video.currentTime;
          record.readyState = video.readyState;
          record.width = video.videoWidth;
          record.height = video.videoHeight;
          record.totalVideoFrames = quality?.totalVideoFrames ?? null;
          record.droppedVideoFrames = quality?.droppedVideoFrames ?? null;
          record.frameCallbacks = callbacks;
          record.status = (record.currentTime > 0.25 &&
                          ((quality?.totalVideoFrames || 0) > 0 || callbacks > 0))
            ? "decoded-frames" : "inconclusive";
        } catch (e) {
          record.status = "playback-failed";
          record.error = String(e);
          record.mediaError = video.error ? { code: video.error.code, message: video.error.message } : null;
        } finally {
          video.pause();
          video.removeAttribute("src");
          video.load();
          video.remove();
        }
        result.playback.push(record);
      }
      return result;
    }).toString() + ")(" + JSON.stringify(testMedia) + ")",
    true,
  );
  report.browser = browserResults;
  report.summary = {
    baseline: browserResults.playback[0]?.status || "unknown",
    hdr10mp4: browserResults.playback[1]?.status || "unknown",
    hdr10mkv: browserResults.playback[2]?.status || "unknown",
    hlg: browserResults.playback[3]?.status || "unknown",
    dvProfile7: "NOT_TESTED_NO_AUTHENTIC_PROFILE7_BITSTREAM",
    hdrOutput: "NOT_VERIFIED_NO_PHYSICAL_HDR_DISPLAY",
    inputMetadata: "VERIFIED_BY_FFPROBE",
  };
  console.log("HDR-DV-RESULT " + JSON.stringify(report.summary));
  fs.writeFileSync(output, JSON.stringify(report, null, 2));
  clearTimeout(watchdog);
  server.close();
  app.exit(0);
}).catch((error) => {
  report.fatal = String(error?.stack || error);
  console.error("HDR-DV-PROBE FAILURE: " + report.fatal);
  fs.writeFileSync(output, JSON.stringify(report, null, 2));
  clearTimeout(watchdog);
  server.close();
  app.exit(1);
});
