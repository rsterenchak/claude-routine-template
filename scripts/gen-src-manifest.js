// Build helper — writes the current source inventory to src-manifest.json so the
// in-app Claude assistant's Worker can fetch an always-current file list, and the
// dashboard's Structure tab can render its Code lens plus a second lens (UI
// regions for web repos, a type outline for C#).
//
// ─────────────────────────────────────────────────────────────────
// TEMPLATE INSTANTIATION NOTES
// Two identical copies ship: gen-src-manifest.js and gen-src-manifest.cjs. Both
// are plain CommonJS. Keep the .cjs when package.json declares "type": "module";
// keep the .js otherwise.
//
// Environment knobs (the onboard script sets these from the detected shape):
//   MANIFEST_LANG        — "web" (default) scans src/ for JS/JSX/TS/CSS/HTML and
//                          extracts UI regions (lens:"ui"); "csharp" walks the
//                          repo for .cs files and extracts a best-effort type
//                          outline — classes/interfaces/structs/enums/records and
//                          their members (lens:"types"); "sql" walks the repo for
//                          .sql files and extracts a best-effort table outline —
//                          CREATE TABLE blocks and their columns/constraints
//                          (lens:"sql"). "doc" walks the repo for .md/.markdown
//                          and emits just the file list (lens:"doc") — enough to
//                          light up the Code lens for a docs/notes repo, no
//                          second-lens payload. More language modes slot in here
//                          later.
//   MANIFEST_OUT_DIR     — where to write src-manifest.json, relative to the
//                          script's parent. Default "dist"; "." for served-from-
//                          source / publish-only repos.
//   MANIFEST_DETERMINISTIC — "true" omits generatedAt/sha so the manifest only
//                          changes when files/regions change.
//   MANIFEST_SRC_ROOT    — web: repo-root-relative path of src/, for GitHub blob
//                          links (else derived from the git root). csharp/sql: an
//                          optional subfolder to scope the .cs/.sql walk to; paths
//                          are always emitted repo-root-relative.
//
// Manifest shape (additive — `files` keeps its prior meaning): files, srcRoot,
// regions, hasDom, lens ("ui" | "types" | "sql"), and — in csharp mode — types
// (a per-type outline, each with a members list), or — in sql mode — tables (a
// per-table outline, each with a columns list). Plus generatedAt/sha unless
// deterministic. A repo with no source is handled gracefully (empty
// files/regions/types/tables, hasDom:false).
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

// ── web mode: recursive JS/JSX/TS/TSX/CSS/HTML inventory, src-relative paths ──
// Mirrors the csharp/sql/doc walkers below. Paths are emitted relative to
// srcDir — NOT repo-root — because web mode publishes srcRoot separately and
// the consumer joins the two. A flat src/ therefore yields exactly the bare
// filenames it always did, so this is a no-op for single-level projects and
// only adds depth where depth exists (Angular's src/app/**, a React repo with
// src/components/**). Directories are filtered by name; everything else is
// filtered by extension, so an assets/ dir of images costs one readdir and
// contributes nothing.
const WEB_SKIP_DIRS = { '.git': 1, node_modules: 1, dist: 1, build: 1, coverage: 1, '.vs': 1, '.idea': 1 };
function walkWeb(start) {
  const out = [];
  (function rec(dir) {
    let ents;
    try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
    ents.forEach(function (e) {
      if (e.isDirectory()) {
        if (!WEB_SKIP_DIRS[e.name] && e.name.charAt(0) !== '.') rec(path.join(dir, e.name));
      } else if (SCAN_RE.test(e.name)) {
        // SCAN_RE is the superset of FILE_RE, so one walk feeds both the
        // inventory and the region scan; they're split by filter below.
        out.push(path.join(dir, e.name));
      }
    });
  })(start);
  return out;
}

function buildWebManifest() {
  let files = [], sources = [];
  try {
    const rel = function (p) { return path.relative(srcDir, p).split(path.sep).join('/'); };
    const names = walkWeb(srcDir).map(rel);
    files = names.filter(function (f) { return FILE_RE.test(f); }).sort();
    sources = names.filter(function (f) { return SCAN_RE.test(f); }).map(function (f) {
      return { name: f, isJs: isJsName(f), text: fs.readFileSync(path.join(srcDir, f), 'utf8') };
    });
  } catch (e) { files = []; sources = []; }
  const regions = scanRegions(sources);
  const hasDom = files.some(function (f) { return /\.(?:jsx?|tsx?|css|html?)$/i.test(f); });
  return { files: files, srcRoot: resolveSrcRoot(), regions: regions, hasDom: hasDom, lens: 'ui' };
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

// ── csharp type outline (best-effort) ──────────────────────────────
// Regex parse of each .cs into its declared types and their members (methods,
// constructors, properties), for the Structure tab's Types lens. A navigation
// aid, NOT a compiler: comments and string/char literals are blanked first
// (offset-preserving) to cut false positives, but heavy/nested generics,
// indexers/operators, and members that follow a NESTED type may be approximate
// (members are attached to the nearest preceding type by source position).
const CS_KW_NAME = { 'if':1,'for':1,'foreach':1,'while':1,'switch':1,'using':1,'lock':1,'catch':1,'fixed':1,'return':1,'throw':1,'yield':1,'await':1,'new':1,'sizeof':1,'typeof':1,'nameof':1,'default':1,'checked':1,'unchecked':1,'when':1,'do':1,'else':1,'in':1,'is':1,'as':1,'get':1,'set':1,'init':1,'add':1,'remove':1,'where':1,'select':1,'from':1 };
const CS_RT_STMT  = { 'return':1,'throw':1,'yield':1,'await':1,'case':1,'goto':1,'else':1,'do':1,'new':1,'in':1 };
const CS_TYPE_KW  = { 'class':1,'interface':1,'struct':1,'enum':1,'record':1,'namespace':1 };
const CS_MAX_TYPES_PER_FILE = 40;
const CS_MAX_MEMBERS_PER_TYPE = 60;
const CS_MAX_TYPES_TOTAL = 600;

const CS_TYPE_DECL_RE = /\b(class|interface|struct|enum|record)[ \t]+([A-Za-z_]\w*)/gd;
const CS_METHOD_RE = /(?:^|[\n;{}])[ \t]*(?:(?:\[[^\]\n]*\][ \t]*)*)(?:(?:public|private|protected|internal|static|virtual|override|abstract|sealed|async|extern|unsafe|partial|new)[ \t]+)*([A-Za-z_][\w.]*(?:<[^;{}()\n]*>)?(?:\[[ \t]*\])?\??)[ \t]+([A-Za-z_]\w*)(?:<[^>(){};\n]*>)?[ \t]*\(([^()]*)\)[ \t\r\n]*(?:where[^={;\n]+)?[ \t\r\n]*(?:=>|\{|;)/gd;
const CS_PROP_RE = /(?:^|[\n;{}])[ \t]*(?:(?:\[[^\]\n]*\][ \t]*)*)(?:(?:public|private|protected|internal|static|virtual|override|abstract|sealed|readonly|new|required)[ \t]+)*([A-Za-z_][\w.]*(?:<[^;{}()\n]*>)?(?:\[[ \t]*\])?\??)[ \t]+([A-Za-z_]\w*)[ \t\r\n]*(?:\{(?=[^}]*\b(?:get|set|init)\b)|=>)/gd;

// Blank comments + string/char literals to spaces, preserving newlines and
// total length so match offsets still map to original line numbers.
function csBlankNonCode(src) {
  let out = '';
  const n = src.length;
  let i = 0;
  while (i < n) {
    const c = src[i], d = i + 1 < n ? src[i + 1] : '';
    if (c === '/' && d === '/') { while (i < n && src[i] !== '\n') { out += ' '; i++; } continue; }
    if (c === '/' && d === '*') {
      out += '  '; i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) { out += src[i] === '\n' ? '\n' : ' '; i++; }
      if (i < n) { out += '  '; i += 2; }
      continue;
    }
    const verbatim = (c === '@' && d === '"') || ((c === '$' || c === '@') && (d === '@' || d === '$') && src[i + 2] === '"');
    if (verbatim) {
      while (i < n && src[i] !== '"') { out += ' '; i++; }
      if (i < n) { out += ' '; i++; }
      while (i < n) {
        if (src[i] === '"' && src[i + 1] === '"') { out += '  '; i += 2; continue; }
        if (src[i] === '"') { out += ' '; i++; break; }
        out += src[i] === '\n' ? '\n' : ' '; i++;
      }
      continue;
    }
    if (c === '"' || (c === '$' && d === '"')) {
      if (c === '$') { out += ' '; i++; }
      out += ' '; i++;
      while (i < n && src[i] !== '"' && src[i] !== '\n') {
        if (src[i] === '\\') { out += '  '; i += 2; continue; }
        out += ' '; i++;
      }
      if (i < n && src[i] === '"') { out += ' '; i++; }
      continue;
    }
    if (c === "'") {
      out += ' '; i++;
      while (i < n && src[i] !== "'" && src[i] !== '\n') {
        if (src[i] === '\\') { out += '  '; i += 2; continue; }
        out += ' '; i++;
      }
      if (i < n && src[i] === "'") { out += ' '; i++; }
      continue;
    }
    out += c; i++;
  }
  return out;
}

function csLineIndexer(src) {
  const starts = [0];
  for (let i = 0; i < src.length; i++) if (src[i] === '\n') starts.push(i + 1);
  return function (idx) {
    let lo = 0, hi = starts.length - 1, ans = 0;
    while (lo <= hi) { const mid = (lo + hi) >> 1; if (starts[mid] <= idx) { ans = mid; lo = mid + 1; } else hi = mid - 1; }
    return ans + 1;
  };
}

function csClean(s) { return String(s == null ? '' : s).replace(/\s+/g, ' ').trim(); }

function scanCsharpTypes(rawSrc, relPath) {
  const src = csBlankNonCode(rawSrc);
  const lineAt = csLineIndexer(src);
  let m;

  // 1. type declarations (sorted by position, capped per file)
  const decls = [];
  CS_TYPE_DECL_RE.lastIndex = 0;
  while ((m = CS_TYPE_DECL_RE.exec(src)) !== null) {
    if (decls.length >= CS_MAX_TYPES_PER_FILE) break;
    const at = m.indices[2][0];
    decls.push({ name: m[2], kind: m[1], file: relPath, line: lineAt(at), index: at, members: [] });
  }
  if (!decls.length) return [];
  decls.sort(function (a, b) { return a.index - b.index; });

  function ownerFor(idx) {
    let chosen = null;
    for (let k = 0; k < decls.length; k++) { if (decls[k].index <= idx) chosen = decls[k]; else break; }
    return chosen;
  }
  const seen = {};
  function addMember(at, kind, name, signature) {
    const owner = ownerFor(at);
    if (!owner || owner.members.length >= CS_MAX_MEMBERS_PER_TYPE) return;
    const key = owner.name + '|' + name + '|' + signature;
    if (seen[key]) return;
    seen[key] = 1;
    owner.members.push({ name: name, kind: kind, signature: signature, line: lineAt(at) });
  }

  // 2. methods — return type is mandatory, which excludes bare calls like
  // Foo(); and control flow like if (...) (no name between keyword and paren).
  CS_METHOD_RE.lastIndex = 0;
  while ((m = CS_METHOD_RE.exec(src)) !== null) {
    const name = m[2];
    if (CS_KW_NAME[name] || CS_TYPE_KW[name]) continue;
    const rt = csClean(m[1]);
    if (!rt || CS_RT_STMT[rt.split(' ').pop()]) continue;
    addMember(m.indices[2][0], 'method', name, name + '(' + csClean(m[3]) + ')');
  }

  // 3. constructors — name matches a type declared in this file.
  const names = decls.map(function (d) { return d.name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); });
  const uniq = names.filter(function (v, k) { return names.indexOf(v) === k; });
  if (uniq.length) {
    const ctorRe = new RegExp('(?:^|[\\n;{}])[ \\t]*(?:(?:public|private|protected|internal|static)[ \\t]+)*\\b(' + uniq.join('|') + ')[ \\t]*\\(([^()]*)\\)[ \\t\\r\\n]*(?::[^={;\\n]+)?[ \\t\\r\\n]*\\{', 'gd');
    while ((m = ctorRe.exec(src)) !== null) {
      addMember(m.indices[1][0], 'method', m[1], m[1] + '(' + csClean(m[2]) + ')');
    }
  }

  // 4. properties — auto / full / expression-bodied. The get|set|init lookahead
  // and the no-paren shape exclude fields and methods respectively.
  CS_PROP_RE.lastIndex = 0;
  while ((m = CS_PROP_RE.exec(src)) !== null) {
    const name = m[2];
    if (CS_KW_NAME[name]) continue;
    const type = csClean(m[1]);
    const tLast = type.split(' ').pop();
    if (!type || CS_TYPE_KW[tLast] || CS_RT_STMT[tLast]) continue;
    addMember(m.indices[2][0], 'property', name, name + ' : ' + type);
  }

  return decls.map(function (d) {
    d.members.sort(function (a, b) { return a.line - b.line; });
    return { name: d.name, kind: d.kind, file: d.file, line: d.line, members: d.members };
  });
}

function buildCsharpManifest() {
  const walkRoot = process.env.MANIFEST_SRC_ROOT ? path.resolve(repoRoot, process.env.MANIFEST_SRC_ROOT) : repoRoot;
  let absFiles = [];
  try { absFiles = walkCs(walkRoot); } catch (e) { absFiles = []; }
  const rel = function (p) { return path.relative(repoRoot, p).split(path.sep).join('/'); };
  const files = absFiles.map(rel).sort();
  // Best-effort type outline for the Structure tab's Types lens. Read each .cs
  // and extract its declared types + members; bounded so a large solution can't
  // bloat the manifest.
  const types = [];
  absFiles.forEach(function (abs) {
    if (types.length >= CS_MAX_TYPES_TOTAL) return;
    let text;
    try { text = fs.readFileSync(abs, 'utf8'); } catch (e) { return; }
    scanCsharpTypes(text, rel(abs)).forEach(function (t) { if (types.length < CS_MAX_TYPES_TOTAL) types.push(t); });
  });
  types.sort(function (a, b) { return a.file < b.file ? -1 : a.file > b.file ? 1 : a.line - b.line; });
  // No DOM: empty regions + hasDom:false. Paths are repo-root-relative so
  // srcRoot stays empty. lens:'types' tells the Structure tab to show the type
  // outline (Code | Types) instead of the DOM map (Code | UI).
  return { files: files, srcRoot: '', regions: [], hasDom: false, types: types, lens: 'types' };
}

// ── sql mode: recursive .sql inventory, repo-root-relative paths ──
// Regex parse of each .sql into its CREATE TABLE blocks and their columns +
// table-level constraints, for the Structure tab's SQL lens. Like the csharp
// scanner it's best-effort, NOT a SQL parser: it assumes the common one-
// definition-per-line CREATE TABLE style (multi-line body, ')' closing on its
// own line). A column/constraint line becomes the row `signature`; a REFERENCES
// clause surfaces as `ref` for inline FK rendering. lens:'sql' + a `tables`
// array mirror csharp's lens:'types' + `types`, so one outline renderer serves
// both (table ↔ type, column ↔ member).
const SQL_MAX_TABLES_TOTAL = 600;
const SQL_MAX_COLS_PER_TABLE = 120;
const SQL_SKIP_DIRS = { '.git': 1, node_modules: 1, dist: 1, '.vs': 1, '.idea': 1 };
const SQL_CREATE_RE = /^\s*CREATE\s+(?:GLOBAL\s+|LOCAL\s+)?(?:TEMP(?:ORARY)?\s+|UNLOGGED\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["'`]?([A-Za-z_][\w.]*)["'`]?/i;
const SQL_CONSTRAINT_RE = /^(?:PRIMARY\s+KEY|FOREIGN\s+KEY|UNIQUE|CHECK|CONSTRAINT|EXCLUDE|LIKE)\b/i;
const SQL_REF_RE = /REFERENCES\s+["'`]?([A-Za-z_][\w.]*)["'`]?\s*(?:\(\s*["'`]?(\w+)["'`]?\s*\))?/i;

function walkSql(start) {
  const out = [];
  (function rec(dir) {
    let ents;
    try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
    ents.forEach(function (e) {
      if (e.isDirectory()) {
        if (!SQL_SKIP_DIRS[e.name] && e.name.charAt(0) !== '.') rec(path.join(dir, e.name));
      } else if (/\.sql$/i.test(e.name)) {
        out.push(path.join(dir, e.name));
      }
    });
  })(start);
  return out;
}

function sqlClean(s) { return String(s == null ? '' : s).replace(/,\s*$/, '').replace(/\s+/g, ' ').trim(); }

// One line inside a CREATE TABLE body → a column or a table-level constraint.
function parseSqlMember(rawLine, lineNo) {
  const trimmed = rawLine.trim();
  if (!trimmed || trimmed.indexOf('--') === 0) return null;
  const signature = sqlClean(rawLine);
  if (!signature) return null;
  const refM = SQL_REF_RE.exec(trimmed);
  const ref = refM ? (refM[2] ? refM[1] + '(' + refM[2] + ')' : refM[1]) : null;
  if (SQL_CONSTRAINT_RE.test(trimmed)) {
    const named = /^CONSTRAINT\s+["'`]?(\w+)/i.exec(trimmed);
    const kw = /^(PRIMARY\s+KEY|FOREIGN\s+KEY|UNIQUE|CHECK|EXCLUDE|LIKE)/i.exec(trimmed);
    const name = named ? named[1] : (kw ? kw[1].replace(/\s+/g, ' ').toUpperCase() : 'constraint');
    return { name: name, kind: 'constraint', signature: signature, line: lineNo, ref: ref };
  }
  const nameM = /^["'`]?([A-Za-z_]\w*)["'`]?/.exec(trimmed);
  const name = nameM ? nameM[1] : firstToken(trimmed);
  return { name: name, kind: 'column', signature: signature, line: lineNo, ref: ref };
}

function scanSqlTables(rawSrc, relPath) {
  const lines = String(rawSrc == null ? '' : rawSrc).split(/\r?\n/);
  const tables = [];
  let cur = null, open = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i], lineNo = i + 1;
    if (!cur) {
      const m = SQL_CREATE_RE.exec(line);
      // '(' may sit on the CREATE line or a later one; wait for it before
      // reading column/constraint lines.
      if (m) { cur = { name: m[1], kind: 'table', file: relPath, line: lineNo, columns: [] }; open = line.indexOf('(') !== -1; }
      continue;
    }
    if (!open) { if (line.indexOf('(') !== -1) open = true; continue; }
    if (/^\s*\)/.test(line)) { tables.push(cur); cur = null; open = false; continue; }
    if (cur.columns.length >= SQL_MAX_COLS_PER_TABLE) continue;
    const member = parseSqlMember(line, lineNo);
    if (member) cur.columns.push(member);
  }
  if (cur) tables.push(cur); // unterminated block — keep what we have
  return tables;
}

function buildSqlManifest() {
  const walkRoot = process.env.MANIFEST_SRC_ROOT ? path.resolve(repoRoot, process.env.MANIFEST_SRC_ROOT) : repoRoot;
  let absFiles = [];
  try { absFiles = walkSql(walkRoot); } catch (e) { absFiles = []; }
  const rel = function (p) { return path.relative(repoRoot, p).split(path.sep).join('/'); };
  const files = absFiles.map(rel).sort();
  // Best-effort table outline for the Structure tab's SQL lens. Read each .sql
  // and extract its CREATE TABLE blocks; bounded so a large schema can't bloat
  // the manifest.
  const tables = [];
  absFiles.forEach(function (abs) {
    if (tables.length >= SQL_MAX_TABLES_TOTAL) return;
    let text;
    try { text = fs.readFileSync(abs, 'utf8'); } catch (e) { return; }
    scanSqlTables(text, rel(abs)).forEach(function (t) { if (tables.length < SQL_MAX_TABLES_TOTAL) tables.push(t); });
  });
  tables.sort(function (a, b) { return a.file < b.file ? -1 : a.file > b.file ? 1 : a.line - b.line; });
  // No DOM: empty regions + hasDom:false. Paths are repo-root-relative so
  // srcRoot stays empty. lens:'sql' tells the Structure tab to show the table
  // outline (Code | SQL) instead of the DOM map (Code | UI).
  return { files: files, srcRoot: '', regions: [], hasDom: false, tables: tables, lens: 'sql' };
}

// ── doc mode: recursive .md inventory, file list only ──
// The thinnest lens-publishing mode: walk the repo for Markdown and emit just
// the file list, so the Structure tab's Code lens (file tree + Explain + View
// on GitHub) lights up for a docs/notes repo. No content scan — there's no
// second-lens payload, so the second slot falls back to the empty UI lens
// ("no UI surface"). lens:'doc' is forward-compatible: a later heading-outline
// upgrade adds an outline payload + a renderDocLens without changing this
// value. Paths are repo-root-relative so srcRoot stays empty.
const DOC_SKIP_DIRS = { '.git': 1, node_modules: 1, dist: 1, '.vs': 1, '.idea': 1 };

function walkDoc(start) {
  const out = [];
  (function rec(dir) {
    let ents;
    try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
    ents.forEach(function (e) {
      if (e.isDirectory()) {
        if (!DOC_SKIP_DIRS[e.name] && e.name.charAt(0) !== '.') rec(path.join(dir, e.name));
      } else if (/\.(md|markdown|mdx)$/i.test(e.name)) {
        out.push(path.join(dir, e.name));
      }
    });
  })(start);
  return out;
}

function buildDocManifest() {
  const walkRoot = process.env.MANIFEST_SRC_ROOT ? path.resolve(repoRoot, process.env.MANIFEST_SRC_ROOT) : repoRoot;
  let absFiles = [];
  try { absFiles = walkDoc(walkRoot); } catch (e) { absFiles = []; }
  const rel = function (p) { return path.relative(repoRoot, p).split(path.sep).join('/'); };
  const files = absFiles.map(rel).sort();
  // File list only, no DOM, no second-lens payload. The Code lens renders the
  // tree; the UI lens reads "no UI surface".
  return { files: files, srcRoot: '', regions: [], hasDom: false, lens: 'doc' };
}

function finalize(base) {
  const deterministic = process.env.MANIFEST_DETERMINISTIC === 'true';
  return deterministic
    ? base
    : Object.assign({ generatedAt: new Date().toISOString(), sha: process.env.GITHUB_SHA || '' }, base);
}

function buildManifest() {
  let base;
  if (LANG === 'csharp' || LANG === 'cs' || LANG === 'dotnet') base = buildCsharpManifest();
  else if (LANG === 'sql' || LANG === 'postgres' || LANG === 'postgresql') base = buildSqlManifest();
  else if (LANG === 'doc' || LANG === 'docs' || LANG === 'markdown') base = buildDocManifest();
  else base = buildWebManifest();
  return finalize(base);
}

module.exports = { scanRegions: scanRegions, prettify: prettify, buildManifest: buildManifest, walkCs: walkCs, walkSql: walkSql, walkDoc: walkDoc };

if (require.main === module) {
  const manifest = buildManifest();
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, 'src-manifest.json'), JSON.stringify(manifest, null, 2));
  console.log(
    'src-manifest.json [' + LANG + '] written to ' + outDirName + '/ —',
    manifest.files.length, 'files,',
    manifest.regions.length, 'regions,',
    (manifest.types ? manifest.types.length : 0), 'types,',
    (manifest.tables ? manifest.tables.length : 0), 'tables, hasDom=' + manifest.hasDom + ', lens=' + manifest.lens
  );
}
