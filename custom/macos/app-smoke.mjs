// Drives the packaged Lampa.app over the DevTools protocol: waits for a page
// target, reads the document and captures a screenshot, so "the bundle builds"
// becomes "the bundle starts and renders".
import fs from 'node:fs';

const [port, output, screenshot] = process.argv.slice(2);
if (!port || !output) {
  console.error('usage: app-smoke.mjs <devtools-port> <output.json> [screenshot.png]');
  process.exit(2);
}
const base = `http://127.0.0.1:${port}`;

const report = {
  port: Number(port),
  pageTarget: null,
  title: null,
  url: null,
  readyState: null,
  hasVideoElement: null,
  screenshot: null,
  error: null,
};

try {
  const deadline = Date.now() + 90000;
  let page = null;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${base}/json/list`);
      const targets = await response.json();
      page = targets.find((target) => target.type === 'page' && target.webSocketDebuggerUrl);
      if (page) break;
    } catch (error) {
      // The debugging port is not up yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
  if (!page) throw new Error('no page target appeared within 90s');
  report.pageTarget = { id: page.id, url: page.url, title: page.title };

  const socket = new WebSocket(page.webSocketDebuggerUrl);
  let nextId = 0;
  const pending = new Map();
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    const resolve = pending.get(message.id);
    if (resolve) {
      pending.delete(message.id);
      resolve(message);
    }
  });
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', () => reject(new Error('devtools socket failed')), { once: true });
  });
  const send = (method, params = {}) => {
    const id = ++nextId;
    socket.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve) => pending.set(id, resolve));
  };

  await send('Page.enable');
  await send('Runtime.enable');
  const evaluated = await send('Runtime.evaluate', {
    expression: `JSON.stringify({
      title: document.title,
      url: location.href,
      ready: document.readyState,
      video: !!document.querySelector('video'),
      bodyLength: document.body ? document.body.innerHTML.length : 0
    })`,
    returnByValue: true,
  });
  const value = JSON.parse(evaluated.result.result.value);
  report.title = value.title;
  report.url = value.url;
  report.readyState = value.ready;
  report.hasVideoElement = value.video;
  report.bodyLength = value.bodyLength;

  if (screenshot) {
    const captured = await send('Page.captureScreenshot', { format: 'png' });
    if (captured?.result?.data) {
      fs.writeFileSync(screenshot, Buffer.from(captured.result.data, 'base64'));
      report.screenshot = screenshot;
    }
  }
  socket.close();
  report.pass = true;
} catch (error) {
  report.error = String((error && error.message) || error);
  report.pass = false;
}

fs.writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
process.exit(report.pass ? 0 : 1);
