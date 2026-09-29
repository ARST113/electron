// Publishes the committed AC3 5.1 sample over a local BitTorrent tracker, so the
// torrent check does not depend on the health of any public swarm. TorrServer
// announces to the same tracker and pulls the file over TCP like any peer.
import fs from 'node:fs';
import path from 'node:path';

const [file, portArgument] = process.argv.slice(2);
if (!file) {
  console.error('usage: torrent-seed.mjs <file> [tracker-port]');
  process.exit(2);
}
const port = Number(portArgument || 8099);

const trackerModule = await import('bittorrent-tracker');
const TrackerServer = trackerModule.Server || (trackerModule.default && trackerModule.default.Server);
const webtorrentModule = await import('webtorrent');
const WebTorrent = webtorrentModule.default || webtorrentModule;

const server = new TrackerServer({ udp: false, http: true, ws: true, stats: false });
await new Promise((resolve, reject) => {
  server.once('error', reject);
  server.listen(port, '127.0.0.1', resolve);
});
const announce = [`http://127.0.0.1:${port}/announce`];
console.log('TRACKER_READY', announce[0]);

const client = new WebTorrent({ dht: false, lsd: false, tracker: { announce } });
const torrent = client.seed(fs.readFileSync(file), {
  name: path.basename(file, path.extname(file)),
  announce,
});

torrent.on('ready', () => {
  console.log('SEED_READY ' + torrent.magnetURI);
});
torrent.on('warning', (warning) => console.log('seeder warning:', warning.message));
torrent.on('error', (error) => {
  console.error('seeder error:', error);
  process.exit(1);
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    client.destroy();
    server.close();
    process.exit(0);
  });
}
