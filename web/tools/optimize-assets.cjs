// Shrinks the assets that ship with the resource WITHOUT changing what they show or contain:
//   · the map atlas tiles (web/public/atlas, copied into html/atlas by `npm run build`) and the event banner images are
//     re-encoded as optimised JPEG (mozjpeg) — the same files, the same names, visually identical, ~3-4x smaller
//   · the race-track JSON in data/tracks is minified (same values, no whitespace)
// A file is only rewritten when the new one is smaller, so it is safe to run again. Keep the originals if you want them back.
//
//   cd web && npm i --no-save sharp && node tools/optimize-assets.cjs [--dry]
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const dry = process.argv.includes('--dry');
const resource = path.resolve(__dirname, '..', '..');
const ATLAS_Q = 78;      // map tiles: flat colours + text, they take heavy compression well
const BANNER_Q = 82;     // photos / art: a little more headroom

const kb = (n) => (n / 1024 / 1024).toFixed(2) + ' MB';
const walk = (dir, ext, out = []) => {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, ext, out);
    else if (e.name.toLowerCase().endsWith(ext)) out.push(p);
  }
  return out;
};

async function jpegs(label, files, quality) {
  let before = 0, after = 0, changed = 0;
  for (const f of files) {
    const buf = fs.readFileSync(f);
    before += buf.length;
    const next = await sharp(buf).jpeg({ quality, mozjpeg: true }).toBuffer();
    if (next.length < buf.length) {
      after += next.length; changed++;
      if (!dry) fs.writeFileSync(f, next);
    } else after += buf.length;
  }
  console.log(`${label}: ${files.length} files, ${changed} rewritten, ${kb(before)} -> ${kb(after)}`);
}

function minifyJson(label, files) {
  let before = 0, after = 0, changed = 0;
  for (const f of files) {
    const text = fs.readFileSync(f, 'utf8');
    before += Buffer.byteLength(text);
    let min;
    try { min = JSON.stringify(JSON.parse(text)); } catch (e) { after += Buffer.byteLength(text); continue; }
    if (Buffer.byteLength(min) < Buffer.byteLength(text)) {
      after += Buffer.byteLength(min); changed++;
      if (!dry) fs.writeFileSync(f, min);
    } else after += Buffer.byteLength(text);
  }
  console.log(`${label}: ${files.length} files, ${changed} rewritten, ${kb(before)} -> ${kb(after)}`);
}

(async () => {
  await jpegs('map atlas (web/public/atlas)', walk(path.join(resource, 'web', 'public', 'atlas'), '.jpg'), ATLAS_Q);
  await jpegs('event banners (images/)', walk(path.join(resource, 'images', 'event_announcement_banner_images'), '.jpg'), BANNER_Q);
  minifyJson('race tracks (data/tracks)', walk(path.join(resource, 'data', 'tracks'), '.json'));
  if (dry) console.log('(dry run: nothing was written)');
})();
