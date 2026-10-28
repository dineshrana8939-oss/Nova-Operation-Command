// Builds a CLEAN copy of the resource for a server: only what the server and the players' clients actually use.
// Left out: web/ (source + node_modules, ~35 MB — only needed to rebuild the UI), local tool folders, backups, build logs, source maps.
// Nothing in the running resource changes; this only writes a new folder.
//
//   node web/tools/make-release.cjs [--out <folder>]
//   default output: <server root>/_nova_convoytruck_release/nova_convoytruck   (outside resources/, so it is never loaded)
// Upload that folder (or zip it) to the server. Run `cd web && npm run build` first if you changed the UI.
const fs = require('fs');
const path = require('path');

const resource = path.resolve(__dirname, '..', '..');
const serverRoot = path.resolve(resource, '..', '..', '..');
const argOut = process.argv.indexOf('--out');
const out = path.resolve(argOut > -1 ? process.argv[argOut + 1] : path.join(serverRoot, '_nova_convoytruck_release', path.basename(resource)));

const DIRS = ['client', 'server', 'shared', 'config', 'bridge', 'data', 'html', 'images', 'sounds', 'stream', 'docs'];
const FILES = ['fxmanifest.lua', 'install.sql', 'ADDON_VEHICLES.md'];
const SKIP = (name) => name.endsWith('.map') || name === 'build.log' || name === 'Thumbs.db' || name === '.DS_Store';

if (out.startsWith(resource + path.sep)) { console.error('The output folder must be outside the resource.'); process.exit(1); }

let files = 0, bytes = 0;
function copy(src, dst) {
  const st = fs.statSync(src);
  if (st.isDirectory()) {
    fs.mkdirSync(dst, { recursive: true });
    for (const n of fs.readdirSync(src)) if (!SKIP(n)) copy(path.join(src, n), path.join(dst, n));
  } else {
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.copyFileSync(src, dst);
    files++; bytes += st.size;
  }
}

fs.rmSync(out, { recursive: true, force: true });
for (const d of DIRS) if (fs.existsSync(path.join(resource, d))) copy(path.join(resource, d), path.join(out, d));
for (const f of FILES) if (fs.existsSync(path.join(resource, f))) copy(path.join(resource, f), path.join(out, f));

// every file the manifest names must be in the copy
const manifest = fs.readFileSync(path.join(out, 'fxmanifest.lua'), 'utf8');
const named = [...manifest.matchAll(/'([^'@*][^']*\.(?:lua|html|yft|ytd|json))'/g)].map((m) => m[1]);
const missing = named.filter((n) => !n.includes('*') && !fs.existsSync(path.join(out, n)));

console.log(`release: ${out}`);
console.log(`${files} files, ${(bytes / 1024 / 1024).toFixed(1)} MB`);
if (missing.length) { console.log('MISSING from the copy:', missing.join(', ')); process.exit(2); }
console.log(`manifest check: ${named.length} named files, all present`);
