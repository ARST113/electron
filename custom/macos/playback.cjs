'use strict';
// Playback probe: plays a local file or a TorrServer stream through a media
// element, taps the decoded audio with Web Audio and writes the captured PCM to
// a 16-bit WAV file. This is the check that proves sound is really produced:
// the WAV is uploaded as evidence and can be listened to.
const { app, BrowserWindow } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const [source, output, secondsArg, wavArg] = process.argv.slice(2);
if (!source || !output) {
  console.error('usage: playback.cjs <file-or-url> <output.json> [seconds] [wav]');
  process.exit(2);
}
const seconds = Number(secondsArg || 20);
const wav = wavArg || '';

app.commandLine.appendSwitch('disable-gpu');
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');
app.commandLine.appendSwitch('disable-web-security');
app.commandLine.appendSwitch('allow-file-access-from-files');
app.disableHardwareAcceleration();

app
  .whenReady()
  .then(async () => {
    const window = new BrowserWindow({
      show: false,
      width: 800,
      height: 600,
      webPreferences: {
        backgroundThrottling: false,
        nodeIntegration: true,
        contextIsolation: false,
        webSecurity: false,
      },
    });
    await window.loadFile(path.join(__dirname, 'harness.html'));

    const result = await window.webContents.executeJavaScript(`(async () => {
      const fs = require('node:fs');
      const source = ${JSON.stringify(source)};
      const seconds = ${JSON.stringify(seconds)};
      const wavPath = ${JSON.stringify(wav)};
      const video = document.createElement('video');
      video.muted = false;
      video.volume = 1;
      video.preload = 'auto';
      video.crossOrigin = 'anonymous';
      video.playsInline = true;
      document.body.appendChild(video);
      const context = new AudioContext({ sampleRate: 48000 });
      await context.resume();
      const tap = context.createMediaElementSource(video);
      const silent = context.createGain();
      silent.gain.value = 0;
      const processor = context.createScriptProcessor(4096, 2, 2);
      const chunks = [];
      processor.onaudioprocess = event => {
        chunks.push(
          Float32Array.from(event.inputBuffer.getChannelData(0)),
          Float32Array.from(event.inputBuffer.getChannelData(1))
        );
      };
      tap.connect(processor);
      processor.connect(silent);
      silent.connect(context.destination);
      const started = Date.now();
      let playError = null;
      video.src = source;
      try {
        await video.play();
      } catch (error) {
        playError = String(error);
      }
      await new Promise(resolve => {
        const timer = setInterval(() => {
          if (Date.now() - started >= seconds * 1000) {
            clearInterval(timer);
            resolve();
          }
        }, 250);
      });
      const played = video.currentTime;
      video.pause();
      let frames = 0;
      let energy = 0;
      let peak = 0;
      for (const chunk of chunks) {
        frames += chunk.length;
        for (const value of chunk) {
          energy += value * value;
          const magnitude = Math.abs(value);
          if (magnitude > peak) peak = magnitude;
        }
      }
      const rms = frames ? Math.sqrt(energy / frames) : 0;
      if (wavPath && chunks.length) {
        const channels = 2;
        const sampleRate = context.sampleRate;
        const chunkSize = chunks[0].length;
        const perChannel = Math.round(chunks.length / channels) * chunkSize;
        const buffer = Buffer.alloc(44 + perChannel * channels * 2);
        buffer.write('RIFF', 0);
        buffer.writeUInt32LE(36 + perChannel * channels * 2, 4);
        buffer.write('WAVE', 8);
        buffer.write('fmt ', 12);
        buffer.writeUInt32LE(16, 16);
        buffer.writeUInt16LE(1, 20);
        buffer.writeUInt16LE(channels, 22);
        buffer.writeUInt32LE(sampleRate, 24);
        buffer.writeUInt32LE(sampleRate * channels * 2, 28);
        buffer.writeUInt16LE(channels * 2, 32);
        buffer.writeUInt16LE(16, 34);
        buffer.write('data', 36);
        buffer.writeUInt32LE(perChannel * channels * 2, 40);
        let offset = 44;
        for (let pair = 0; pair < chunks.length; pair += 2) {
          const left = chunks[pair];
          const right = chunks[pair + 1] || new Float32Array(left.length);
          for (let index = 0; index < left.length; index++) {
            const a = Math.max(-1, Math.min(1, left[index]));
            const b = Math.max(-1, Math.min(1, right[index]));
            buffer.writeInt16LE(Math.round(a * 32767), offset);
            buffer.writeInt16LE(Math.round(b * 32767), offset + 2);
            offset += 4;
          }
        }
        fs.writeFileSync(wavPath, buffer);
      }
      return {
        played: playError === null,
        playError,
        currentTime: played,
        readyState: video.readyState,
        duration: Number.isFinite(video.duration) ? video.duration : null,
        networkState: video.networkState,
        decodedAudioBytes: video.webkitAudioDecodedByteCount || 0,
        decodedVideoFrames: video.webkitDecodedFrameCount || 0,
        mediaError: video.error ? { code: video.error.code, message: video.error.message } : null,
        contextState: context.state,
        sampleRate: context.sampleRate,
        capturedFrames: frames,
        capturedSeconds: frames / 2 / context.sampleRate,
        rms,
        peak,
        wav: wavPath ? fs.existsSync(wavPath) : false,
      };
    })()`);

    result.pass =
      result.rms > 0.005 &&
      result.capturedFrames > 0 &&
      (result.decodedAudioBytes > 0 || result.decodedVideoFrames > 0);
    fs.writeFileSync(output, JSON.stringify(result, null, 2) + '\n');
    console.log(JSON.stringify(result, null, 2));
    app.exit(0);
  })
  .catch((error) => {
    console.error(error);
    try {
      fs.writeFileSync(output, JSON.stringify({ pass: false, error: String(error) }, null, 2) + '\n');
    } catch (ignored) {
      /* nothing else we can do */
    }
    app.exit(1);
  });
