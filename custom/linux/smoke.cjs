const { app, BrowserWindow } = require('electron');
const fs = require('node:fs');
const path = require('node:path');

const [fixtures, output] = process.argv.slice(2);
app.commandLine.appendSwitch('disable-gpu');
app.whenReady().then(async () => {
  if (process.versions.electron !== '44.4.4') throw new Error('Wrong Electron version');
  const window = new BrowserWindow({ show: false, webPreferences: { backgroundThrottling: false } });
  await window.loadURL('about:blank');
  const report = { versions: process.versions, platform: process.platform, arch: process.arch, codecs: [] };
  for (const codec of ['ac3', 'eac3']) {
    const base64 = fs.readFileSync(path.join(fixtures, `${codec}.mp4`)).toString('base64');
    const decoded = await window.webContents.executeJavaScript(`(async () => {
      const data = Uint8Array.from(atob(${JSON.stringify(base64)}), c => c.charCodeAt(0));
      const context = new OfflineAudioContext(2, 48000, 48000);
      const buffer = await Promise.race([
        context.decodeAudioData(data.buffer),
        new Promise((_, reject) => setTimeout(() => reject(new Error('Decode timeout')), 20000))
      ]);
      const samples = buffer.getChannelData(0);
      let energy = 0;
      for (const value of samples) energy += value * value;
      return { frames: buffer.length, duration: buffer.duration, channels: buffer.numberOfChannels,
        rms: Math.sqrt(energy / samples.length), sampleRate: buffer.sampleRate };
    })()`);
    if (decoded.duration < 0.9 || decoded.rms < 0.01 || !Number.isFinite(decoded.rms)) {
      throw new Error(`${codec}: decoded PCM is missing or silent: ${JSON.stringify(decoded)}`);
    }
    report.codecs.push({ codec, ...decoded });
  }
  fs.writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report, null, 2));
  app.exit(0);
}).catch(error => { console.error(error); app.exit(1); });
