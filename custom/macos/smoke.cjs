'use strict';
// Decoding probe: decodes the committed AC3/EAC3 fixtures into PCM inside the
// custom Electron runtime and records duration, channel count and RMS energy.
// A silent result means the runtime cannot decode AC3/EAC3 at all.
const { app, BrowserWindow } = require('electron');
const fs = require('node:fs');
const path = require('node:path');

const [fixtures, output] = process.argv.slice(2);
if (!fixtures || !output) {
  console.error('usage: smoke.cjs <fixtures-dir> <output.json>');
  process.exit(2);
}

app.commandLine.appendSwitch('disable-gpu');
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');
app.disableHardwareAcceleration();

app
  .whenReady()
  .then(async () => {
    const report = {
      electron: process.versions.electron,
      chrome: process.versions.chrome,
      node: process.versions.node,
      platform: process.platform,
      arch: process.arch,
      codecs: [],
    };
    const window = new BrowserWindow({
      show: false,
      width: 640,
      height: 480,
      webPreferences: { backgroundThrottling: false },
    });
    await window.loadFile(path.join(__dirname, 'harness.html'));

    for (const codec of ['ac3', 'eac3']) {
      const base64 = fs.readFileSync(path.join(fixtures, `${codec}.mp4`)).toString('base64');
      let result;
      try {
        result = await window.webContents.executeJavaScript(`(async () => {
          const bytes = Uint8Array.from(atob(${JSON.stringify(base64)}), c => c.charCodeAt(0));
          const context = new OfflineAudioContext(2, 48000, 48000);
          const buffer = await Promise.race([
            context.decodeAudioData(bytes.buffer),
            new Promise((_, reject) => setTimeout(() => reject(new Error('decode timeout')), 30000))
          ]);
          const samples = buffer.getChannelData(0);
          let energy = 0;
          for (const value of samples) energy += value * value;
          return { decoded: true, frames: buffer.length, duration: buffer.duration,
            channels: buffer.numberOfChannels, sampleRate: buffer.sampleRate,
            rms: Math.sqrt(energy / samples.length) };
        })()`);
      } catch (error) {
        result = { decoded: false, error: String((error && error.message) || error) };
      }
      result.pass =
        result.decoded === true && result.duration > 1.5 && Number.isFinite(result.rms) && result.rms > 0.01;
      report.codecs.push({ codec, ...result });
    }

    fs.writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
    console.log(JSON.stringify(report, null, 2));
    app.exit(0);
  })
  .catch((error) => {
    console.error(error);
    app.exit(1);
  });
