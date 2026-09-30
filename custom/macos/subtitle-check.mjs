// Checks subtitles the way the application itself does: it loads the app's own
// subtitleToolPath and subtitleExtractor modules, resolves the tools bundled into
// the packaged bundle and then probes and extracts real text subtitles from a live
// stream. This proves the macOS bundle can show subtitles without any external
// ffmpeg installation.
//
// Usage: subtitle-check.mjs <source app dir> <packaged Resources dir> <url> <output.json> <out.vtt> [stream index] [start seconds]
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const [appDir, resourcesPath, url, output, vttPath, indexArg, startArg] = process.argv.slice(2);
if (!appDir || !resourcesPath || !url || !output) {
  console.error('usage: subtitle-check.mjs <app dir> <resources dir> <url> <output.json> <out.vtt> [index] [start]');
  process.exit(2);
}
const require = createRequire(import.meta.url);
const { subtitleToolPath } = require(path.join(appDir, 'src/modules/subtitleToolPath.js'));
const { probeSubtitles, extractSubtitles } = require(path.join(appDir, 'src/modules/subtitleExtractor.js'));

const report = {
  resourcesPath,
  ffmpeg: null,
  ffprobe: null,
  probe: null,
  streams: [],
  extractedBytes: 0,
  cues: 0,
  vtt: null,
  error: null,
  pass: false,
};

try {
  report.ffmpeg = subtitleToolPath({ platform: 'darwin', isPackaged: true, resourcesPath, probing: false });
  report.ffprobe = subtitleToolPath({ platform: 'darwin', isPackaged: true, resourcesPath, probing: true });
  if (!fs.existsSync(report.ffmpeg)) throw new Error(`bundled ffmpeg is not inside the bundle: ${report.ffmpeg}`);
  if (!fs.existsSync(report.ffprobe)) throw new Error(`bundled ffprobe is not inside the bundle: ${report.ffprobe}`);

  const request = { url, streamIndex: 0, start: 0, id: 'ci-probe' };
  const probe = await probeSubtitles(report.ffprobe, request).promise;
  report.probe = { success: probe.success, message: probe.message || null };
  report.streams = (probe.streams || []).map((stream) => ({
    index: stream.index,
    codec: stream.codec_name,
    language: stream.tags?.language || null,
    title: stream.tags?.title || null,
  }));
  if (!probe.success) throw new Error(`subtitle probe failed: ${probe.message}`);

  const textStreams = report.streams.filter((stream) => /subrip|ass|ssa|webvtt|text/i.test(stream.codec || ''));
  report.textStreams = textStreams.length;
  if (!textStreams.length) throw new Error('no text subtitle streams were reported');

  const streamIndex = indexArg ? Number(indexArg) : textStreams[0].index;
  const start = startArg ? Number(startArg) : 60;
  const chunks = [];
  const extraction = extractSubtitles(report.ffmpeg, { url, streamIndex, start, id: 'ci-extract' }, (text) => chunks.push(text));
  const result = await extraction.promise;
  const vtt = chunks.join('');
  report.extractedBytes = Buffer.byteLength(vtt);
  report.cues = (vtt.match(/-->/g) || []).length;
  report.streamIndex = streamIndex;
  report.start = start;
  report.extraction = { success: result.success, message: result.message || null };
  if (vttPath) {
    fs.writeFileSync(vttPath, vtt);
    report.vtt = vttPath;
  }
  if (!result.success) throw new Error(`subtitle extraction failed: ${result.message}`);
  if (report.cues < 1) throw new Error('no subtitle cues were extracted');
  report.pass = true;
} catch (error) {
  report.error = String((error && error.message) || error);
  if (vttPath && !fs.existsSync(vttPath)) fs.writeFileSync(vttPath, '');
}

fs.writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
process.exit(report.pass ? 0 : 1);
