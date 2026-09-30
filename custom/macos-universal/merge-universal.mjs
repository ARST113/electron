// Merges the Intel and Apple Silicon Electron.app bundles into one universal
// bundle with @electron/universal, the same tool electron-builder uses for its
// universal target. Mach-O files are lipo-joined, the remaining resources must be
// identical in both inputs.
//
// Usage: merge-universal.mjs <x64 Electron.app> <arm64 Electron.app> <out Electron.app>
import { makeUniversalApp } from '@electron/universal';
import fs from 'node:fs';
import path from 'node:path';

const [x64App, arm64App, outApp] = process.argv.slice(2);
if (!x64App || !arm64App || !outApp) {
  console.error('usage: merge-universal.mjs <x64 app> <arm64 app> <out app>');
  process.exit(2);
}
for (const candidate of [x64App, arm64App]) {
  if (!fs.existsSync(candidate)) throw new Error(`missing input application: ${candidate}`);
}

// When neither input carries an application ASAR, @electron/universal compares
// Contents/Resources/app of the two bundles - and a bare Electron distribution
// has no such folder at all, so the comparison dies with ENOENT before any
// Mach-O file is touched. Empty placeholders let it through; they are removed
// again so the merged runtime keeps the original layout.
const placeholders = [];
for (const app of [x64App, arm64App]) {
  const directory = path.join(app, 'Contents', 'Resources', 'app');
  if (!fs.existsSync(directory)) {
    fs.mkdirSync(directory, { recursive: true });
    placeholders.push(directory);
  }
}

try {
  await makeUniversalApp({
    x64AppPath: x64App,
    arm64AppPath: arm64App,
    outAppPath: outApp,
    force: true,
    // A plain Electron distribution has no application ASAR of its own, so only
    // Mach-O files need joining.
    mergeASARs: false,
  });
  console.log('universal application written to', outApp);
} finally {
  for (const directory of placeholders) {
    fs.rmSync(directory, { recursive: true, force: true });
  }
  fs.rmSync(path.join(outApp, 'Contents', 'Resources', 'app'), { recursive: true, force: true });
}
