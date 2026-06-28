// Build helper — writes the current source inventory to src-manifest.json so the
// in-app Claude assistant's Worker can fetch an always-current file list, and the
// dashboard's Structure tab can render its Code lens and (for web repos) UI lens.
//
// ─────────────────────────────────────────────────────────────────
// TEMPLATE INSTANTIATION NOTES
// Two identical copies ship: gen-src-manifest.js and gen-src-manifest.cjs. Both
// are plain CommonJS. Keep the .cjs when package.json declares "type": "module";
// keep the .js otherwise.
//
// Environment knobs (the onboard script sets these from the detected shape):
//   MANIFEST_LANG        — "web" (default) scans src/ for JS/JSX/TS/CSS/HTML and
//                          extracts UI regions; "csharp" walks the repo for .cs
//                          files (a flat code inventory, no UI regions). More
//                          language modes (sql, docs) slot in here later.
//   MANIFEST_OUT_DIR     — where to write src-manifest.json, relative to the
//                          script's parent. Default "dist"; "." for served-from-
//                          source / publish-only repos.
//   MANIFEST_DETERMINISTIC — "true" omits generatedAt/sha so the manifest only
//                          changes when files/regions change.
//   MANIFEST_SRC_ROOT    — web: repo-root-relative path of src/, for GitHub blob
//                          links (else derived from the git root). csharp: an
//                          optional subfolder to scope the .cs walk to; paths
//                          are always emitted repo-root-relative.
//
// Manifest shape (additive — `files` keeps its prior meaning): files, srcRoot,
// regions, hasDom, plus generatedAt/sha unless deterministic. A repo with no
// source is handled gracefully (empty files/regions, hasDom:false).
// ─────────────────────────────────────────────────────────────────

const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..');
const srcDir = path.resolve(__dirname, '..', 'src');
const outDirName = process.env.MANIFEST_OUT_DIR || 'dist';
const outDir = path.resolve(__dirname, '..', outDirName);
const LANG = (process.env.MANIFEST_LANG || 'web').toLowerCase();

const FILE_RE = /\.(?:jsx?|tsx?|css)$/;        // web files inventory (Code lens)
const SCAN_RE = /\.(?:jsx?|tsx?|css|html?)$/;   // web files scanned for handles
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

// ── web region scan (unchanged) ─────────────────────────────────
function scanRegions(sources) {
  const list = Array.isArray(sources) ? sources : [];
  const occ = [];
  const definedIds = new Set();
  const definedRegions = new Set();
  const definedClasses = new Set();
  function pushOcc(selector, label, file, line, isJs) {
    occ.push({ selector: selector, label: label, file: file, line: line, isJs: !!isJs });
  }
  list.forEach(function (s) {
    if (/\.css$/i.test(s.name)) return;
    String(s.text || '').split(/\r?\n/).forEach(function (line, i) {
      const ln = i + 1; let m;
      const idAssign = /(?<![\w-])id\s*[:=]\s*['"]([A-Za-z][\w-]*)['"]/g;
      while ((m = idAssign.exec(line))) { definedIds.add(m[1]); pushOcc('#' + m[1], prettify(m[1]), s.name, ln, s.isJs); }
      const idSet = /['"]id['"]\s*,\s*['"]([A-Za-z][\w-]*)['"]/g;
      while ((m = idSet.exec(line))) { definedIds.add(m[1]); pushOcc('#' + m[1], prettify(m[1]), s.name, ln, s.isJs); }
      const drAttr = /data-region\s*[:=]\s*['"]([^'"]+)['"]/g;
      while ((m = drAttr.exec(line))) { definedRegions.add(m[1]); pushOcc('[data-region="' + m[1] + '"]', m[1], s.name, ln, s.isJs); }
      const drSet = /data-region['"]\s*,\s*['"]([^'"]+)['"]/g;
      while ((m = drSet.exec(line))) { definedRegions.add(m[1]); pushOcc('[data-region="' + m[1] + '"]', m[1], s.name, ln, s.isJs); }
      const clsAttr = /\bclassName\s*=\s*['"]([^'"]+)['"]/g;
      while ((m = clsAttr.exec(line))) { const t = firstToken(m[1]); if (isName(t)) { definedClasses.add(t); pushOcc('.' + t, prettify(t), s.name, ln, s.isJs); } }
      const clsBrace = /\bclassName\s*=\s*\{\s*['"`]([^'"`]+)['"`]\s*\}/g;
      while ((m = clsBrace.exec(line))) { const t = firstToken(m[1]); if (isName(t)) { definedClasses.add(t); pushOcc('.' + t, prettify(t), s.name, ln, s.isJs); } }
      const clsPlain = /(?<![-\w])class\s*=\s*['"]([^'"]+)['"]/g;
      while ((m = clsPlain.exec(line))) { const t = firstToken(m[1]); if (isName(t)) { definedClasses.add(t); pushOcc('.' + t, prettify(t), s.name, ln, s.isJs); } }
    });
  });
  list.forEach(function (s) {
    if (!/\.css$/i.test(s.name)) return;
    String(s.text || '').split(/\r?\n/).forEach(function (line, i) {
      const ln = i + 1; let m;
      const idUse = /#([A-Za-z][\w-]*)/g;
      while ((m = idUse.exec(line))) { if (definedIds.has(m[1])) pushOcc('#' + m[1], prettify(m[1]), s.name, ln, false); }
      const drUse = /\[data-region[~^$*|]?=['"]?([^\]'"]+)['"]?\]/g;
      while ((m = drUse.exec(line))) { if (definedRegions.has(m[1])) pushOcc('[data-region="' + m[1] + '"]', m[1], s.name, ln, false); }
      const clsUse = /\.([A-Za-z][\w-]*)/g;
      while ((m = clsUse.exec(line))) { if (definedClasses.has(m[1])) pushOcc('.' + m[1], prettify(m[1]), s.name, ln, false); }
    });
  });
  const byKey = new Map();
  occ.forEach(function (o) {
    const key = o.selector + '\n' + o.file;
    const prev = byKey.get(key);
    if (!prev || o.line < prev.line) byKey.set(key, o);
  });
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
    regions.push({ selector: selector, label: primary.label, file: primary.file, line: primary.line,
      files: group.map(function (o) { return { file: o.file, line: o.line }; }) });
  });
  regions.sort(function (a, b) { return a.selector < b.selector ? -1 : (a.selector > b.selector ? 1 : 0); });
  return regions;
}

function buildWebManifest() {
  let files = [], sources = [];
  try {
    const names = fs.readdirSync(srcDir);
    files = names.filter(function (f) { return FILE_RE.test(f); }).sort();
    sources = names.filter(function (f) { return SCAN_RE.test(f); }).map(function (f) {
      return { name: f, isJs: isJsName(f), text: fs.readFileSync(path.join(srcDir, f), 'utf8') };
    });
  } catch (e) { files = []; sources = []; }
  const regions = scanRegions(sources);
  const hasDom = files.some(function (f) { return /\.(?:jsx?|tsx?|css|html?)$/i.test(f); });
  return { files: files, srcRoot: resolveSrcRoot(), regions: regions, hasDom: hasDom };
}

// ── csharp mode: recursive .cs inventory, repo-root-relative paths ──
const CS_SKIP_DIRS = { bin: 1, obj: 1, '.git': 1, '.vs': 1, '.idea': 1, node_modules: 1, packages: 1, TestResults: 1, dist: 1 };
const CS_SKIP_FILE = /\.(?:Designer|g|g\.i|AssemblyInfo)\.cs$/i;
function walkCs(start) {
  const out = [];
  (function rec(dir) {
    let ents;
    try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
    ents.forEach(function (e) {
      if (e.isDirectory()) {
        if (!CS_SKIP_DIRS[e.name] && e.name.charAt(0) !== '.') rec(path.join(dir, e.name));
      } else if (/\.cs$/i.test(e.name) && !CS_SKIP_FILE.test(e.name)) {
        out.push(path.join(dir, e.name));
      }
    });
  })(start);
  return out;
}

function buildCsharpManifest() {
  const walkRoot = process.env.MANIFEST_SRC_ROOT ? path.resolve(repoRoot, process.env.MANIFEST_SRC_ROOT) : repoRoot;
  let files = [];
  try {
    files = walkCs(walkRoot)
      .map(function (p) { return path.relative(repoRoot, p).split(path.sep).join('/'); })
      .sort();
  } catch (e) { files = []; }
  // No DOM: empty regions + hasDom:false makes the UI lens render "no UI surface".
  // Paths are repo-root-relative, so srcRoot stays empty (the consumer's GitHub
  // link prefixes srcRoot only when present).
  return { files: files, srcRoot: '', regions: [], hasDom: false };
}

function finalize(base) {
  const deterministic = process.env.MANIFEST_DETERMINISTIC === 'true';
  return deterministic
    ? base
    : Object.assign({ generatedAt: new Date().toISOString(), sha: process.env.GITHUB_SHA || '' }, base);
}

function buildManifest() {
  const base = (LANG === 'csharp' || LANG === 'cs' || LANG === 'dotnet')
    ? buildCsharpManifest()
    : buildWebManifest();
  return finalize(base);
}

module.exports = { scanRegions: scanRegions, prettify: prettify, buildManifest: buildManifest, walkCs: walkCs };

if (require.main === module) {
  const manifest = buildManifest();
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, 'src-manifest.json'), JSON.stringify(manifest, null, 2));
  console.log(
    'src-manifest.json [' + LANG + '] written to ' + outDirName + '/ —',
    manifest.files.length, 'files,', manifest.regions.length, 'regions, hasDom=' + manifest.hasDom
  );
}
