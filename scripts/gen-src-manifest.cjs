// Build helper — writes the current source inventory to src-manifest.json so the
// in-app Claude assistant's Worker can fetch an always-current file list, and the
// dashboard's Structure tab can render its Code lens (the file list) and UI lens.
//
// ─────────────────────────────────────────────────────────────────
// TEMPLATE INSTANTIATION NOTES
// Two identical copies ship in the template: gen-src-manifest.js and
// gen-src-manifest.cjs. Both are plain CommonJS. Keep the .cjs when the repo's
// package.json declares "type": "module" (Node would otherwise treat a .js as
// ESM and the require() calls would fail); keep the .js otherwise.
//
// Environment knobs (the onboard script sets these from the detected shape):
//   MANIFEST_OUT_DIR     — where to write src-manifest.json, relative to the
//                          script's parent. Default "dist"; "." for served-from-
//                          source projects (served from the repo root, no build).
//   MANIFEST_DETERMINISTIC — "true" omits generatedAt/sha so the manifest only
//                          changes when files/regions change (served-from-source
//                          projects commit it back to the branch).
//   MANIFEST_SRC_ROOT    — repo-root-relative path of the scanned src/ folder,
//                          used to build GitHub blob links. Optional: if unset,
//                          it's derived by finding the git root (works whether
//                          the project sits at the repo root or in a subfolder).
//
// Emits (all keys ADDITIVE — `files` keeps its exact prior shape):
//   • regions  — id / data-region / className handles, each mapped to its
//                defining file+line and a `files:[{file,line}]` list of every
//                occurrence (JS/JSX definition preferred as primary owner).
//                Powers the UI lens's published map + "Find in code".
//   • srcRoot  — so the consumer can build GitHub blob deep links.
//   • hasDom   — whether the repo has any web/UI surface, so a DOM-less repo
//                (console / SQL / docs) renders a distinct "no UI surface" state.
// A repo with no src/ is handled gracefully (empty files/regions, hasDom:false).
// ─────────────────────────────────────────────────────────────────

const fs = require('fs');
const path = require('path');

const srcDir = path.resolve(__dirname, '..', 'src');
const outDirName = process.env.MANIFEST_OUT_DIR || 'dist';
const outDir = path.resolve(__dirname, '..', outDirName);

const FILE_RE = /\.(?:jsx?|tsx?|css)$/;        // files inventory (Code lens)
const SCAN_RE = /\.(?:jsx?|tsx?|css|html?)$/;   // files scanned for handles
function isJsName(name) { return /\.(?:jsx?|tsx?)$/.test(name); }

// Mirror structureView's prettify so live and published labels read identically.
function prettify(token) {
  return String(token || '')
    .replace(/[-_]+/g, ' ')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/\b\w/g, function (c) { return c.toUpperCase(); });
}
function isName(s) { return /^[A-Za-z_][\w-]*$/.test(s); }
function firstToken(v) { return String(v).trim().split(/\s+/)[0] || ''; }

// repo-root-relative path of src/. Prefer the explicit override; else walk up
// for a .git dir and compute relative to it; else fall back to the folder name.
function resolveSrcRoot() {
  if (process.env.MANIFEST_SRC_ROOT) {
    return process.env.MANIFEST_SRC_ROOT.replace(/^[/\\]+|[/\\]+$/g, '').split(path.sep).join('/');
  }
  let dir = srcDir;
  for (let i = 0; i < 12; i++) {
    if (fs.existsSync(path.join(dir, '.git'))) {
      return path.relative(dir, srcDir).split(path.sep).join('/');
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return path.basename(srcDir);
}

// Scan `{ name, isJs, text }` sources for id / data-region / className handles
// and group them into regions. Pure (no fs / no module state) so it's unit-
// testable. Regex-based and deliberately approximate — a nav aid, not a parser.
function scanRegions(sources) {
  const list = Array.isArray(sources) ? sources : [];
  const occ = [];
  const definedIds = new Set();
  const definedRegions = new Set();
  const definedClasses = new Set();

  function pushOcc(selector, label, file, line, isJs) {
    occ.push({ selector: selector, label: label, file: file, line: line, isJs: !!isJs });
  }

  // Pass 1 — JS / JSX / HTML: id, data-region, and className DEFINITIONS.
  list.forEach(function (s) {
    if (/\.css$/i.test(s.name)) return;
    String(s.text || '').split(/\r?\n/).forEach(function (line, i) {
      const ln = i + 1;
      let m;
      // id = 'x' / id: 'x' / el.id = "x" / id="x" — but not data-id= etc.
      const idAssign = /(?<![\w-])id\s*[:=]\s*['"]([A-Za-z][\w-]*)['"]/g;
      while ((m = idAssign.exec(line))) { definedIds.add(m[1]); pushOcc('#' + m[1], prettify(m[1]), s.name, ln, s.isJs); }
      const idSet = /['"]id['"]\s*,\s*['"]([A-Za-z][\w-]*)['"]/g;        // setAttribute('id','x')
      while ((m = idSet.exec(line))) { definedIds.add(m[1]); pushOcc('#' + m[1], prettify(m[1]), s.name, ln, s.isJs); }
      const drAttr = /data-region\s*[:=]\s*['"]([^'"]+)['"]/g;
      while ((m = drAttr.exec(line))) { definedRegions.add(m[1]); pushOcc('[data-region="' + m[1] + '"]', m[1], s.name, ln, s.isJs); }
      const drSet = /data-region['"]\s*,\s*['"]([^'"]+)['"]/g;           // setAttribute('data-region','x')
      while ((m = drSet.exec(line))) { definedRegions.add(m[1]); pushOcc('[data-region="' + m[1] + '"]', m[1], s.name, ln, s.isJs); }
      // className="x y" / className={'x'} / className={`x ${..}`} / HTML class="x"
      const clsAttr = /\bclassName\s*=\s*['"]([^'"]+)['"]/g;
      while ((m = clsAttr.exec(line))) { const t = firstToken(m[1]); if (isName(t)) { definedClasses.add(t); pushOcc('.' + t, prettify(t), s.name, ln, s.isJs); } }
      const clsBrace = /\bclassName\s*=\s*\{\s*['"`]([^'"`]+)['"`]\s*\}/g;
      while ((m = clsBrace.exec(line))) { const t = firstToken(m[1]); if (isName(t)) { definedClasses.add(t); pushOcc('.' + t, prettify(t), s.name, ln, s.isJs); } }
      const clsPlain = /(?<![-\w])class\s*=\s*['"]([^'"]+)['"]/g;
      while ((m = clsPlain.exec(line))) { const t = firstToken(m[1]); if (isName(t)) { definedClasses.add(t); pushOcc('.' + t, prettify(t), s.name, ln, s.isJs); } }
    });
  });

  // Pass 2 — CSS: record usages, but only for handles already defined above
  // (keeps hex colors like #fff and unrelated selectors out of the index).
  list.forEach(function (s) {
    if (!/\.css$/i.test(s.name)) return;
    String(s.text || '').split(/\r?\n/).forEach(function (line, i) {
      const ln = i + 1;
      let m;
      const idUse = /#([A-Za-z][\w-]*)/g;
      while ((m = idUse.exec(line))) { if (definedIds.has(m[1])) pushOcc('#' + m[1], prettify(m[1]), s.name, ln, false); }
      const drUse = /\[data-region[~^$*|]?=['"]?([^\]'"]+)['"]?\]/g;
      while ((m = drUse.exec(line))) { if (definedRegions.has(m[1])) pushOcc('[data-region="' + m[1] + '"]', m[1], s.name, ln, false); }
      const clsUse = /\.([A-Za-z][\w-]*)/g;
      while ((m = clsUse.exec(line))) { if (definedClasses.has(m[1])) pushOcc('.' + m[1], prettify(m[1]), s.name, ln, false); }
    });
  });

  // Dedupe to the earliest occurrence per (selector, file).
  const byKey = new Map();
  occ.forEach(function (o) {
    const key = o.selector + '\n' + o.file;
    const prev = byKey.get(key);
    if (!prev || o.line < prev.line) byKey.set(key, o);
  });

  // Group by selector; primary owner is the JS/JSX definition when one exists.
  const bySelector = new Map();
  Array.from(byKey.values()).forEach(function (o) {
    if (!bySelector.has(o.selector)) bySelector.set(o.selector, []);
    bySelector.get(o.selector).push(o);
  });

  const regions = [];
  bySelector.forEach(function (group, selector) {
    group.sort(function (a, b) {
      if (a.isJs !== b.isJs) return a.isJs ? -1 : 1;
      if (a.file !== b.file) return a.file < b.file ? -1 : 1;
      return a.line - b.line;
    });
    const primary = group[0];
    regions.push({
      selector: selector,
      label: primary.label,
      file: primary.file,
      line: primary.line,
      files: group.map(function (o) { return { file: o.file, line: o.line }; }),
    });
  });
  regions.sort(function (a, b) { return a.selector < b.selector ? -1 : (a.selector > b.selector ? 1 : 0); });
  return regions;
}

function buildManifest() {
  let files = [];
  let sources = [];
  try {
    const names = fs.readdirSync(srcDir);
    files = names.filter(function (f) { return FILE_RE.test(f); }).sort();
    sources = names.filter(function (f) { return SCAN_RE.test(f); }).map(function (f) {
      return { name: f, isJs: isJsName(f), text: fs.readFileSync(path.join(srcDir, f), 'utf8') };
    });
  } catch (e) {
    files = [];
    sources = [];
  }

  const regions = scanRegions(sources);
  const srcRoot = resolveSrcRoot();
  const hasDom = files.some(function (f) { return /\.(?:jsx?|tsx?|css|html?)$/i.test(f); });

  const deterministic = process.env.MANIFEST_DETERMINISTIC === 'true';
  const base = { files: files, srcRoot: srcRoot, regions: regions, hasDom: hasDom };
  return deterministic
    ? base
    : Object.assign({ generatedAt: new Date().toISOString(), sha: process.env.GITHUB_SHA || '' }, base);
}

module.exports = { scanRegions: scanRegions, prettify: prettify, buildManifest: buildManifest };

if (require.main === module) {
  const manifest = buildManifest();
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, 'src-manifest.json'), JSON.stringify(manifest, null, 2));
  console.log(
    'src-manifest.json written to ' + outDirName + '/ —',
    manifest.files.length, 'files,', manifest.regions.length, 'regions, hasDom=' + manifest.hasDom
  );
}
