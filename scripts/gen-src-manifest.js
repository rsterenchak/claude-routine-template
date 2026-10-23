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
// regions, hasDom, lens ("ui" | "types" | "sql"), and — in web mode — modules
// (per-JS-file lines/imports/purpose) plus areas (copied from a committed
// codemap.json beside scripts/, omitted when absent), or — in csharp mode — types
// (a per-type outline, each with a members list), or — in sql mode — tables (a
// per-table outline, each with a columns list). Plus generatedAt/sha unless
// deterministic. A repo with no source is handled gracefully (empty
// files/regions/types/tables, hasDom:false). csharp types and members carry a
// 1-based `end` line beside `line`.
//
// Web and csharp modes also write src-symbols.json beside the manifest — a
// definitions index for code tracing: { version, files: { path: { defs: [{
// name, kind, start, end, parent }], imports: { localName: { from, name } } } } }.
// Kept separate because the PWA fetches it lazily; never timestamped. In csharp
// mode the keys are the manifest's repo-root-relative .cs paths and `imports`
// is always empty.
//
// When a committed codetour.json sits beside scripts/, web and csharp modes
// compile
// it into src-tours.json — guided code tours whose steps are anchored by
// symbol + match text and enriched with line, area, next and an embedded
// snippet. Deterministic; steps that no longer resolve are warned and dropped.
//
// When a committed codebook.json sits beside scripts/ too, they compile it
// into src-book.json — ordered chapters of prose whose backticked references
// resolve to definitions in the same symbols index, with each chapter's tours
// resolved from the compiled tours. Deterministic; a chapter with a reference,
// file, tour or ahead link that no longer resolves is warned and marked stale.
// A rationale sentence (one giving a reason) must end in a citation marker —
// `[src: file:line]`, `[rule: …]` (CLAUDE.md), `[req: id]` (assignment.md),
// `[commit: hash]` — or be hedged as inference; it compiles to a `why` segment
// tagged cited / unverified / inferred, and an unbacked one is stale.
// `--write-fingerprints` (or MANIFEST_WRITE_FINGERPRINTS=1) stores each
// chapter's code fingerprint in codebook.json — a hash of every referenced
// def's body and importers; a later compile whose code no longer matches marks
// the chapter stale with `drift` naming the changed refs.
// A first chapter of `kind: "map"` is generated instead (rankMapSymbols): the
// code map's areas, each area's front-door files with their purpose lines, and
// each file's most-used names beside their authored roles, emitted as
// `sections` beside the flat paragraphs. `--print-map-candidates` (or
// MANIFEST_PRINT_MAP=1) prints that hierarchy to stderr.
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

// ── web module graph: per-JS-file line count, local imports, purpose ──
// Feeds the Structure tab's Map lens. Best-effort regex parse, NOT a JS
// parser: only relative specifiers are followed (package imports are ignored)
// and whole-line `//` comments are skipped so a commented-out import doesn't
// draw an edge.
const MODULE_PURPOSE_MAX = 140;
const IMPORT_FROM_RE = /\bimport\s+[^'"`;()=]*?\bfrom\s*['"]([^'"]+)['"]/g;
const EXPORT_FROM_RE = /\bexport\s+[^'"`;()=]*?\bfrom\s*['"]([^'"]+)['"]/g;
const DYNAMIC_IMPORT_RE = /\bimport\s*\(\s*(['"`])([^'"`]+)\1\s*\)/g;

// One relative specifier resolved to a src-relative path against `dir`, or
// null for a package import, a template specifier, or one that escapes src/.
// Shared by parseImports and the symbols index so both resolve identically.
function resolveSpecifier(spec, dir, known) {
  if (!/^\.\.?\//.test(spec) || spec.indexOf('${') !== -1) return null;
  let resolved = path.posix.normalize(path.posix.join(dir, spec.split(/[?#]/)[0]));
  if (resolved === '..' || resolved.indexOf('../') === 0) return null;
  if (!known.has(resolved) && known.size) {
    const hit = ['.js', '.jsx', '.ts', '.tsx', '/index.js', '/index.jsx', '/index.ts', '/index.tsx']
      .map(function (ext) { return resolved + ext; })
      .find(function (cand) { return known.has(cand); });
    if (hit) resolved = hit;
  }
  return resolved;
}

// Relative import specifiers in `text`, resolved to src-relative paths against
// `fromPath` (itself src-relative). An extensionless specifier is resolved
// against `knownFiles` (.js/.jsx/.ts/.tsx, then /index.*) when a list is given.
// Specifiers that escape src/ are dropped. De-duplicated and sorted.
function parseImports(text, fromPath, knownFiles) {
  const code = String(text || '').replace(/^[ \t]*\/\/.*$/gm, '');
  const known = new Set(Array.isArray(knownFiles) ? knownFiles : []);
  const dir = path.posix.dirname(String(fromPath || ''));
  const out = new Set();
  function add(spec) {
    const resolved = resolveSpecifier(spec, dir, known);
    if (resolved) out.add(resolved);
  }
  let m;
  IMPORT_FROM_RE.lastIndex = 0;
  while ((m = IMPORT_FROM_RE.exec(code))) add(m[1]);
  EXPORT_FROM_RE.lastIndex = 0;
  while ((m = EXPORT_FROM_RE.exec(code))) add(m[1]);
  DYNAMIC_IMPORT_RE.lastIndex = 0;
  while ((m = DYNAMIC_IMPORT_RE.exec(code))) add(m[2]);
  return Array.from(out).sort();
}

// A comment line that is only a `── TITLE ──` banner, not prose.
const PURPOSE_BANNER_RE = /^[─—=\-\s]*[A-Z0-9 _/()+&.,'-]+[─—=\-\s]*$/;

// First sentence of the file's leading `//` or `/* */` comment block, trimmed
// to MODULE_PURPOSE_MAX chars at a word boundary, or null when the file opens
// with code. A banner first line (and blank comment lines after it) is skipped.
function extractPurpose(text) {
  const lines = String(text || '').replace(/^﻿/, '').replace(/^#!.*\n/, '').split(/\r?\n/);
  let i = 0;
  while (i < lines.length && !lines[i].trim()) i++;
  if (i >= lines.length) return null;
  const parts = [];
  if (/^\s*\/\//.test(lines[i])) {
    for (; i < lines.length && /^\s*\/\//.test(lines[i]); i++) parts.push(lines[i].replace(/^\s*\/\/+/, ''));
  } else if (/^\s*\/\*/.test(lines[i])) {
    for (; i < lines.length; i++) {
      const end = lines[i].indexOf('*/');
      const body = end === -1 ? lines[i] : lines[i].slice(0, end);
      parts.push(body.replace(/^\s*\/\*+/, '').replace(/^\s*\*+/, ''));
      if (end !== -1) break;
    }
  } else {
    return null;
  }
  if (parts.length && parts[0].trim() && PURPOSE_BANNER_RE.test(parts[0].trim())) {
    parts.shift();
    while (parts.length && !parts[0].trim()) parts.shift();
  }
  const joined = parts.join(' ').replace(/\s+/g, ' ').trim();
  if (!joined) return null;
  const sentence = /^(.*?[.!?])(?=\s|$)/.exec(joined);
  const first = sentence ? sentence[1] : joined;
  if (first.length <= MODULE_PURPOSE_MAX) return first;
  // Cut at the last word boundary that leaves room for the ellipsis.
  const cut = first.slice(0, MODULE_PURPOSE_MAX);
  const space = cut.lastIndexOf(' ');
  return (space > 0 ? cut.slice(0, space) : cut.slice(0, MODULE_PURPOSE_MAX - 1)).replace(/[\s,;:—–-]+$/, '') + '…';
}

function countLines(text) {
  const s = String(text || '');
  if (!s) return 0;
  const n = s.split(/\r?\n/).length;
  return /\n$/.test(s) ? n - 1 : n;
}

// [{ path, lines, imports, purpose }] for every JS/JSX/TS/TSX source, sorted
// by path. `sources` is the same { name, isJs, text } list the region scan uses.
function buildModules(sources) {
  const js = (Array.isArray(sources) ? sources : []).filter(function (s) { return s && isJsName(s.name); });
  const names = js.map(function (s) { return s.name; });
  return js.map(function (s) {
    return { path: s.name, lines: countLines(s.text), imports: parseImports(s.text, s.name, names), purpose: extractPurpose(s.text) };
  }).sort(function (a, b) { return a.path < b.path ? -1 : (a.path > b.path ? 1 : 0); });
}

// The committed code map's `areas` array, or undefined when the file is
// absent or unreadable — the manifest then omits the key entirely.
function readCodemapAreas(file) {
  let data;
  try { data = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return undefined; }
  return data && Array.isArray(data.areas) ? data.areas : undefined;
}

// Drift between the code map and the module list: JS files no area claims,
// and area files that no longer exist. Warn-only; never fails the build.
function codemapWarnings(modules, areas) {
  if (!Array.isArray(areas)) return [];
  const paths = (modules || []).map(function (m) { return m.path; });
  const known = new Set(paths);
  const assigned = new Set();
  const missing = [];
  areas.forEach(function (a) {
    ((a && Array.isArray(a.files)) ? a.files : []).forEach(function (f) {
      assigned.add(f);
      if (!known.has(f)) missing.push((a.id || '?') + ': ' + f);
    });
  });
  const unassigned = paths.filter(function (p) { return !assigned.has(p); });
  const warnings = [];
  if (unassigned.length) warnings.push('codemap.json: ' + unassigned.length + ' JS file(s) in no area — ' + unassigned.join(', '));
  if (missing.length) warnings.push('codemap.json: ' + missing.length + ' area file(s) not found — ' + missing.join(', '));
  return warnings;
}

// ── web definitions index (src-symbols.json) ──────────────────────
// Groundwork for tap-to-trace in the code viewer: every definition per JS file
// with its line range and enclosing definition, plus the file's import
// bindings. Published beside the manifest as its own file so the PWA fetches
// it lazily, only on the first trace. Like the module graph this is a best-
// effort scan, NOT a JS parser: comments, strings, template text and regex
// literals are blanked first (offset-preserving), then definitions are found
// by pattern and their bodies closed by brace matching.
const SYMBOLS_VERSION = 1;
const JS_ID = '[A-Za-z_$][\\w$]*';
// Sets, not object literals: `constructor` must not hit Object.prototype.
const JS_CONTROL_KW = new Set(['if', 'for', 'while', 'switch', 'catch', 'function', 'with', 'return', 'typeof', 'do', 'else', 'new', 'delete', 'void', 'throw', 'await', 'yield', 'case', 'in', 'of', 'instanceof', 'super', 'import']);
// After one of these words a `/` opens a regex literal, not a division.
const JS_REGEX_AFTER_WORD = new Set(['return', 'typeof', 'instanceof', 'case', 'do', 'else', 'in', 'of', 'new', 'delete', 'void', 'throw', 'yield', 'await']);
const JS_REGEX_AFTER_CHAR = '(,=:[!&|?{};+-*%<>~^';

// Blank comments, string/template text and regex literals to spaces,
// preserving newlines and total length so offsets map to the original lines.
// Template `${…}` expressions stay code (their own braces balance); the `${`
// and its closing `}` are blanked so they never count toward a body's braces.
function jsBlankNonCode(src) {
  const s = String(src == null ? '' : src);
  const n = s.length;
  const out = s.split('');
  function blank(a, b) { for (let k = a; k < b && k < n; k++) if (out[k] !== '\n') out[k] = ' '; }
  const stack = [];      // 'b' = code brace, 't' = template expression
  let lastSig = -1;      // index of the last significant code char
  // Template text from `i` up to its closing backtick (returns past it) or a
  // `${` (pushes 't' and returns past it, back in code).
  function template(i) {
    const start = i;
    while (i < n) {
      if (s[i] === '\\') { i += 2; continue; }
      if (s[i] === '`') { blank(start, i + 1); return i + 1; }
      if (s[i] === '$' && s[i + 1] === '{') { blank(start, i + 2); stack.push('t'); return i + 2; }
      i++;
    }
    blank(start, n);
    return n;
  }
  function regexAllowed() {
    if (lastSig < 0) return true;
    const c = s[lastSig];
    if (JS_REGEX_AFTER_CHAR.indexOf(c) !== -1) return true;
    if (/[\w$]/.test(c)) {
      let k = lastSig;
      while (k >= 0 && /[\w$]/.test(s[k])) k--;
      return JS_REGEX_AFTER_WORD.has(s.slice(k + 1, lastSig + 1));
    }
    return false;
  }
  let i = 0;
  while (i < n) {
    const c = s[i], d = s[i + 1];
    if (c === '/' && d === '/') { const st = i; while (i < n && s[i] !== '\n') i++; blank(st, i); continue; }
    if (c === '/' && d === '*') {
      const st = i; i += 2;
      while (i < n && !(s[i] === '*' && s[i + 1] === '/')) i++;
      i = Math.min(n, i + 2); blank(st, i); continue;
    }
    if (c === '"' || c === "'") {
      const st = i; i++;
      while (i < n && s[i] !== c && s[i] !== '\n') { if (s[i] === '\\') i++; i++; }
      i = Math.min(n, i + 1); blank(st, i); lastSig = i - 1; continue;
    }
    if (c === '`') { i = template(i + 1); lastSig = i - 1; continue; }
    if (c === '/' && regexAllowed()) {
      const st = i; i++;
      let inClass = false;
      while (i < n && s[i] !== '\n') {
        if (s[i] === '\\') { i += 2; continue; }
        if (s[i] === '[') inClass = true;
        else if (s[i] === ']') inClass = false;
        else if (s[i] === '/' && !inClass) break;
        i++;
      }
      i = Math.min(n, i + 1);
      while (i < n && /[a-z]/i.test(s[i])) i++;
      blank(st, i); lastSig = i - 1; continue;
    }
    if (c === '{') stack.push('b');
    else if (c === '}') {
      if (stack.pop() === 't') { blank(i, i + 1); i = template(i + 1); lastSig = i - 1; continue; }
    }
    if (!/\s/.test(c)) lastSig = i;
    i++;
  }
  return out.join('');
}

// Open-brace index → matching close-brace index over blanked code.
function braceMap(code) {
  const map = new Map();
  const stack = [];
  for (let i = 0; i < code.length; i++) {
    if (code[i] === '{') stack.push(i);
    else if (code[i] === '}' && stack.length) map.set(stack.pop(), i);
  }
  return map;
}

function skipWs(code, i) { while (i < code.length && /\s/.test(code[i])) i++; return i; }

function matchParen(code, open) {
  let depth = 0;
  for (let i = open; i < code.length; i++) {
    if (code[i] === '(') depth++;
    else if (code[i] === ')' && --depth === 0) return i;
  }
  return -1;
}

// The function value starting at `i` in blanked code: a `function` expression,
// an arrow, or (when `allowIife`) a parenthesised function called in place.
// Returns { body } (index of the body's `{`, or -1 for a braceless arrow) and
// `iife: true` for the called-in-place form, or null when `i` isn't a function.
function functionAt(code, i, allowIife) {
  i = skipWs(code, i);
  const asyncM = /^async\b\s*/.exec(code.slice(i, i + 12));
  if (asyncM) i += asyncM[0].length;
  const head = code.slice(i, i + 80);
  let m = /^function\b\s*\*?\s*(?:[A-Za-z_$][\w$]*)?\s*\(/.exec(head);
  if (m) {
    const close = matchParen(code, i + m[0].length - 1);
    if (close < 0) return null;
    const b = skipWs(code, close + 1);
    return code[b] === '{' ? { body: b } : null;
  }
  let afterParams = -1;
  if (code[i] === '(') {
    const close = matchParen(code, i);
    if (close < 0) return null;
    afterParams = skipWs(code, close + 1);
    if (code.slice(afterParams, afterParams + 2) !== '=>') {
      // Not an arrow — a parenthesised expression. `(function () {…})()` /
      // `(() => {…})()` is the IIFE module pattern.
      if (!allowIife || asyncM || code[afterParams] !== '(') return null;
      const inner = functionAt(code, i + 1, false);
      return inner && inner.body >= 0 ? { body: inner.body, iife: true } : null;
    }
  } else if ((m = /^[A-Za-z_$][\w$]*\s*(?==>)/.exec(head))) {
    afterParams = i + m[0].length;
  } else {
    return null;
  }
  const b = skipWs(code, afterParams + 2);
  return { body: code[b] === '{' ? b : -1 };
}

function scanJsDefs(rawSrc) {
  const code = jsBlankNonCode(rawSrc);
  const lineAt = csLineIndexer(code);
  const braces = braceMap(code);
  const lastLine = lineAt(code.length);
  const defs = [];
  const claimed = new Set();   // body `{` indices already owned by a def
  function add(name, kind, nameIdx, body) {
    if (body >= 0) { if (claimed.has(body)) return; claimed.add(body); }
    const close = body >= 0 ? braces.get(body) : undefined;
    const start = lineAt(nameIdx);
    defs.push({ name: name, kind: kind, start: start, end: body < 0 ? start : (close === undefined ? lastLine : lineAt(close)),
      index: nameIdx, open: body, close: close === undefined ? (body < 0 ? -1 : code.length) : close });
  }
  let m, re;
  // 1. const|let|var x = function… / arrow / IIFE (the IIFE owner gets
  // kind "iife" so `X.member` can resolve to a def whose parent is X).
  re = new RegExp('\\b(?:const|let|var)\\s+(' + JS_ID + ')\\s*=(?![=>])', 'g');
  while ((m = re.exec(code))) {
    const fn = functionAt(code, m.index + m[0].length, true);
    if (fn) add(m[1], fn.iife ? 'iife' : 'function', m.index + m[0].indexOf(m[1], m[0].search(/\s/)), fn.body);
  }
  // 2. object-literal methods written as `name: function` / `name: (…) =>`.
  // A `?` before the name means a ternary branch, not a key.
  re = new RegExp('(?<![\\w$.]|\\?\\s*)(' + JS_ID + ')\\s*:(?!:)', 'g');
  while ((m = re.exec(code))) {
    if (JS_CONTROL_KW.has(m[1]) || m[1] === 'default') continue;
    const fn = functionAt(code, m.index + m[0].length, false);
    if (fn) add(m[1], 'method', m.index, fn.body);
  }
  // 3. function declarations at any depth (async / generator included).
  re = new RegExp('\\bfunction\\b\\s*\\*?\\s*(' + JS_ID + ')\\s*\\(', 'g');
  while ((m = re.exec(code))) {
    const close = matchParen(code, m.index + m[0].length - 1);
    if (close < 0) continue;
    const b = skipWs(code, close + 1);
    if (code[b] === '{') add(m[1], 'function', m.index + m[0].lastIndexOf(m[1]), b);
  }
  // 4. class declarations.
  re = new RegExp('\\bclass\\s+(' + JS_ID + ')[^{;]*\\{', 'g');
  while ((m = re.exec(code))) add(m[1], 'class', m.index + m[0].indexOf(m[1]), m.index + m[0].length - 1);
  // 5. class / object shorthand methods: `name(…) {` (control keywords never
  // name a method; a `.` before the name is a call, not a definition).
  re = new RegExp('(?<![\\w$.])(?:(?:static|async|get|set)\\s+)*\\*?\\s*(' + JS_ID + ')\\s*\\(', 'g');
  while ((m = re.exec(code))) {
    if (JS_CONTROL_KW.has(m[1])) continue;
    const open = m.index + m[0].length - 1;
    const close = matchParen(code, open);
    if (close < 0) continue;
    const b = skipWs(code, close + 1);
    if (code[b] === '{') add(m[1], 'method', m.index + m[0].lastIndexOf(m[1], m[0].length - 1), b);
  }
  // Parent = innermost def whose body encloses this def's name.
  const scopes = defs.filter(function (d) { return d.open >= 0; });
  defs.sort(function (a, b) { return a.index - b.index; });
  return defs.map(function (d) {
    let parent = null, best = -1;
    scopes.forEach(function (sc) {
      if (sc.open < d.index && d.index < sc.close && sc.open > best) { best = sc.open; parent = sc.name; }
    });
    return { name: d.name, kind: d.kind, start: d.start, end: d.end, parent: parent };
  });
}

// `import` bindings: localName → { from, name } ("default" / "*" for default
// and namespace imports). Package imports are ignored; specifiers resolve
// exactly as parseImports resolves them.
const IMPORT_CLAUSE_RE = /\bimport\s+([^'"`;()=]*?)\s*\bfrom\s*['"]([^'"]+)['"]/g;
function parseImportBindings(text, fromPath, knownFiles) {
  const code = String(text || '').replace(/^[ \t]*\/\/.*$/gm, '');
  const known = new Set(Array.isArray(knownFiles) ? knownFiles : []);
  const dir = path.posix.dirname(String(fromPath || ''));
  const out = {};
  let m;
  IMPORT_CLAUSE_RE.lastIndex = 0;
  while ((m = IMPORT_CLAUSE_RE.exec(code))) {
    const from = resolveSpecifier(m[2], dir, known);
    if (!from) continue;
    let clause = m[1].replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/^type\s+/, '').trim();
    const def = /^([A-Za-z_$][\w$]*)\s*(?:,|$)/.exec(clause);
    if (def) { out[def[1]] = { from: from, name: 'default' }; clause = clause.slice(def[0].length).trim(); }
    const ns = /^\*\s*as\s+([A-Za-z_$][\w$]*)/.exec(clause);
    if (ns) out[ns[1]] = { from: from, name: '*' };
    const named = /^\{([\s\S]*)\}$/.exec(clause);
    if (named) {
      named[1].split(',').forEach(function (part) {
        const p = /^\s*(?:type\s+)?([A-Za-z_$][\w$]*)(?:\s+as\s+([A-Za-z_$][\w$]*))?\s*$/.exec(part);
        if (p) out[p[2] || p[1]] = { from: from, name: p[1] };
      });
    }
  }
  const sorted = {};
  Object.keys(out).sort().forEach(function (k) { sorted[k] = out[k]; });
  return sorted;
}

// { version, files: { path: { defs, imports } } } for every JS source, keys
// sorted so the output only changes when the source does.
function buildSymbols(sources) {
  const js = (Array.isArray(sources) ? sources : []).filter(function (s) { return s && isJsName(s.name); })
    .sort(function (a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0); });
  const names = js.map(function (s) { return s.name; });
  const files = {};
  js.forEach(function (s) {
    files[s.name] = { defs: scanJsDefs(s.text), imports: parseImportBindings(s.text, s.name, names) };
  });
  return { version: SYMBOLS_VERSION, files: files };
}

// The web inventory (`files`) and the scanned { name, isJs, text } sources
// under `root`; both empty when src/ is missing or unreadable.
function readWebSources(root) {
  try {
    const rel = function (p) { return path.relative(root, p).split(path.sep).join('/'); };
    const names = walkWeb(root).map(rel);
    return {
      files: names.filter(function (f) { return FILE_RE.test(f); }).sort(),
      sources: names.filter(function (f) { return SCAN_RE.test(f); }).map(function (f) {
        return { name: f, isJs: isJsName(f), text: fs.readFileSync(path.join(root, f), 'utf8') };
      }),
    };
  } catch (e) { return { files: [], sources: [] }; }
}

function buildWebSymbols(opts) {
  return buildSymbols(readWebSources((opts && opts.srcDir) || srcDir).sources);
}

function buildWebManifest(opts) {
  const o = opts || {};
  const root = o.srcDir || srcDir;
  const codemapPath = o.codemapPath || path.resolve(root, '..', 'codemap.json');
  const inventory = readWebSources(root);
  const files = inventory.files, sources = inventory.sources;
  const regions = scanRegions(sources);
  const hasDom = files.some(function (f) { return /\.(?:jsx?|tsx?|css|html?)$/i.test(f); });
  const modules = buildModules(sources);
  const areas = readCodemapAreas(codemapPath);
  const warn = o.warn || console.warn;
  codemapWarnings(modules, areas).forEach(function (w) { warn('Warning: ' + w); });
  const manifest = { files: files, srcRoot: resolveSrcRoot(), regions: regions, hasDom: hasDom, lens: 'ui', modules: modules };
  if (areas) manifest.areas = areas;
  return manifest;
}

// ── web code tours (codetour.json → src-tours.json) ───────────────
// Guided walkthroughs for the Structure tab. A committed codetour.json anchors
// each step to a definition (file + symbol, + parent when given) and a list of
// `match` substrings found in order inside that definition — never a line
// number — so tours survive edits. Compiled against the symbols index from the
// same run into real lines, the step's area and an embedded snippet, so the
// PWA needs no extra fetches. Steps that no longer resolve are dropped with a
// warning; a tour left with fewer than TOUR_MIN_STEPS is dropped too.
const TOURS_VERSION = 1;
const TOUR_MIN_STEPS = 3;
const TOUR_SNIPPET_MAX_ROWS = 12;
// Clusters separated by more than this many hidden lines get a gap row;
// closer ones are joined by the lines between them.
const TOUR_SNIPPET_MAX_JOIN = 2;

function readJsonFile(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return undefined; }
}

// A step whose symbol is TOUR_FILE_SYMBOL anchors to the whole file — for
// top-level code no named definition wraps (`parent` is ignored).
const TOUR_FILE_SYMBOL = '@file';

// Defs sharing one `parent` are overloads of one member (C# only — JS has
// none): the first in source order, or null when the parents differ.
function firstOverload(defs) {
  const parent = defs[0].parent === undefined ? null : defs[0].parent;
  let first = defs[0];
  for (let k = 1; k < defs.length; k++) {
    if ((defs[k].parent === undefined ? null : defs[k].parent) !== parent) return null;
    if (defs[k].start < first.start) first = defs[k];
  }
  return first;
}

// { line, lines } for a step, or { error } naming why it didn't resolve.
// `lines` are the 1-based matched lines, ascending.
function resolveTourStep(step, symbols, fileLines) {
  const entry = symbols && symbols.files ? symbols.files[step.file] : null;
  if (!entry) return { error: 'file not in symbols index' };
  const lines = fileLines[step.file] || [];
  let def;
  if (step.symbol === TOUR_FILE_SYMBOL) {
    def = { start: 1, end: lines.length };
  } else {
    const hasParent = step.parent !== undefined && step.parent !== null;
    const defs = entry.defs.filter(function (d) {
      return d.name === step.symbol && (!hasParent || d.parent === step.parent);
    });
    if (!defs.length) return { error: 'symbol not found' };
    def = firstOverload(defs);
    if (!def) return { error: 'symbol is ambiguous (' + defs.length + ' defs) — add a parent' };
  }
  const match = Array.isArray(step.match) ? step.match : [];
  if (!match.length) return { error: 'no match strings' };
  const hits = [];
  for (let m = 0; m < match.length; m++) {
    const from = m === 0 ? def.start : hits[m - 1] + 1;
    let found = 0;
    for (let n = from; n <= def.end; n++) {
      if (lines[n - 1] !== undefined && lines[n - 1].indexOf(match[m]) !== -1) {
        if (m === 0 && found) return { error: 'first match "' + match[0] + '" is not unique in ' + (step.symbol === TOUR_FILE_SYMBOL ? step.file : step.symbol) };
        if (!found) found = n;
        if (m !== 0) break;
      }
    }
    if (!found) return { error: 'match "' + match[m] + '" not found' + (m ? ' after "' + match[m - 1] + '"' : '') };
    hits.push(found);
  }
  return { line: hits[0], lines: hits };
}

// Snippet rows for the matched `hits`: each with one line of context either
// side, clusters closed by gap rows, indentation trimmed per cluster, capped.
function buildTourSnippet(lines, hits) {
  const total = lines.length;
  const ranges = [];
  hits.forEach(function (n) {
    const lo = Math.max(1, n - 1), hi = Math.min(total, n + 1);
    const last = ranges[ranges.length - 1];
    if (last && lo - last.hi - 1 <= TOUR_SNIPPET_MAX_JOIN) last.hi = Math.max(last.hi, hi);
    else ranges.push({ lo: lo, hi: hi });
  });
  const hitSet = new Set(hits);
  const rows = [];
  ranges.forEach(function (r, i) {
    if (i) rows.push({ gap: true });
    const raw = [];
    for (let n = r.lo; n <= r.hi; n++) raw.push(String(lines[n - 1]).replace(/\r$/, ''));
    const indents = raw.filter(function (t) { return t.trim(); }).map(function (t) { return t.match(/^[ \t]*/)[0].length; });
    const cut = indents.length ? Math.min.apply(null, indents) : 0;
    raw.forEach(function (t, k) {
      rows.push({ n: r.lo + k, t: t.trim() ? t.slice(cut) : '', hi: hitSet.has(r.lo + k) });
    });
  });
  const capped = rows.slice(0, TOUR_SNIPPET_MAX_ROWS);
  while (capped.length && capped[capped.length - 1].gap) capped.pop();
  return capped;
}

// The recap cards for `tour` as { title, body } (what tourPlayer renders): a
// string item becomes a title-only card, anything without a non-empty title
// is dropped, each with a warning.
function compileTourRecap(tour, say) {
  const cards = [];
  (Array.isArray(tour.recap) ? tour.recap : []).forEach(function (item, i) {
    const at = 'Warning: codetour.json: tour "' + tour.id + '" recap item ' + (i + 1);
    if (typeof item === 'string' && item) {
      say(at + ' is a string — normalized to { title, body: "" }');
      cards.push({ title: item, body: '' });
    } else if (item && typeof item === 'object' && typeof item.title === 'string' && item.title) {
      cards.push(item);
    } else {
      say(at + ' has no title — item dropped');
    }
  });
  return cards;
}

// { version, sections, tours } compiled from a parsed codetour.json.
// `sources` is the { name, text } list the symbols were built from; `areas`
// the codemap areas (optional).
function compileTours(doc, symbols, sources, areas, warn) {
  const say = warn || console.warn;
  const fileLines = {};
  (Array.isArray(sources) ? sources : []).forEach(function (s) { if (s) fileLines[s.name] = s.text.split('\n'); });
  const areaOf = {};
  (Array.isArray(areas) ? areas : []).forEach(function (a) {
    ((a && Array.isArray(a.files)) ? a.files : []).forEach(function (f) { if (!(f in areaOf)) areaOf[f] = a.id; });
  });
  const tours = [];
  ((doc && Array.isArray(doc.tours)) ? doc.tours : []).forEach(function (tour) {
    const steps = [];
    (Array.isArray(tour.steps) ? tour.steps : []).forEach(function (step, i) {
      const r = resolveTourStep(step, symbols, fileLines);
      if (r.error) {
        say('Warning: codetour.json: tour "' + tour.id + '" step ' + (i + 1) + ' (' + step.file + ' › ' + step.symbol + '): ' + r.error + ' — step dropped');
        return;
      }
      steps.push({
        file: step.file,
        symbol: step.symbol,
        parent: step.parent === undefined || step.symbol === TOUR_FILE_SYMBOL ? null : step.parent,
        title: step.title,
        why: step.why,
        line: r.line,
        area: areaOf[step.file] === undefined ? null : areaOf[step.file],
        next: null,
        snippet: buildTourSnippet(fileLines[step.file], r.lines),
      });
    });
    if (steps.length < TOUR_MIN_STEPS) {
      say('Warning: codetour.json: tour "' + tour.id + '" has ' + steps.length + ' resolved step(s), needs ' + TOUR_MIN_STEPS + ' — tour dropped');
      return;
    }
    // A whole-file step is labelled by its file name, not `@file`.
    const label = function (s) { return s.symbol === TOUR_FILE_SYMBOL ? s.file.split('/').pop() : s.symbol; };
    steps.forEach(function (s, i) { s.next = i + 1 < steps.length ? label(steps[i + 1]) : null; });
    tours.push({ id: tour.id, section: tour.section, title: tour.title, recap: compileTourRecap(tour, say), steps: steps });
  });
  return { version: TOURS_VERSION, sections: (doc && Array.isArray(doc.sections)) ? doc.sections : [], tours: tours };
}

// The compiled tours for the web source under `srcDir`, or null when
// codetour.json is absent (nothing is written then).
function buildWebTours(opts) {
  const o = opts || {};
  const root = o.srcDir || srcDir;
  const doc = readJsonFile(o.tourPath || path.resolve(root, '..', 'codetour.json'));
  if (!doc) return null;
  // `sources` overrides the src/ read — csharp mode passes its .cs list.
  const sources = o.sources || readWebSources(root).sources;
  const symbols = o.symbols || buildSymbols(sources);
  const areas = readCodemapAreas(o.codemapPath || path.resolve(root, '..', 'codemap.json'));
  return compileTours(doc, symbols, sources, areas, o.warn);
}

// Writes src-tours.json into `outDir` when codetour.json exists; returns the
// compiled tours, or null when nothing was written.
function writeWebTours(opts) {
  const o = opts || {};
  const tours = buildWebTours(o);
  if (!tours) return null;
  fs.writeFileSync(path.join(o.outDir || outDir, 'src-tours.json'), JSON.stringify(tours));
  return tours;
}

// ── web code book (codebook.json → src-book.json) ─────────────────
// The codebase told as ordered chapters that read front-to-back once. A
// committed codebook.json holds each chapter's prose; every backticked span in
// a paragraph is a reference, resolved against the symbols index from the same
// run into a { label, file, symbol, parent, line, end } chip, so the reader
// needs no further lookups. A reference, file, tour or ahead link that stops
// resolving is warned and marks its chapter stale instead of shipping wrong.
const BOOK_VERSION = 1;
const BOOK_WORDS_PER_MINUTE = 200;
const BOOK_REF_RE = /`([^`\n]+)`/g;
const BOOK_FILE_RE = /^[\w./-]+\.(?:jsx?|tsx?|mjs|cjs|cs)$/;
const BOOK_NAME_RE = /^(?:([A-Za-z_$][\w$]*)\.)?([A-Za-z_$][\w$]*)$/;

// Defs named `name` (under `parent` when given) across `files`, each as
// { file, def }.
function bookDefsIn(symbols, files, name, parent) {
  const out = [];
  files.forEach(function (f) {
    const entry = symbols.files[f];
    (entry ? entry.defs : []).forEach(function (d) {
      if (d.name === name && (parent === null || d.parent === parent)) out.push({ file: f, def: d });
    });
  });
  return out;
}

// firstOverload over bookDefsIn hits, which must also share one file.
function firstOverloadHit(hits) {
  for (let k = 1; k < hits.length; k++) if (hits[k].file !== hits[0].file) return null;
  const def = firstOverload(hits.map(function (h) { return h.def; }));
  return def ? { file: hits[0].file, def: def } : null;
}

// { ref } for a resolved span, { error } for a broken one, or {} for a span
// that names nothing and stays plain text.
function resolveBookRef(span, chapterFiles, symbols) {
  const label = span;
  const known = Object.keys(symbols.files);
  const toRef = function (hit) {
    return { ref: { label: label, file: hit.file, symbol: hit.def.name, parent: hit.def.parent === undefined ? null : hit.def.parent, line: hit.def.start, end: hit.def.end } };
  };
  if (BOOK_FILE_RE.test(span)) {
    if (!symbols.files[span]) return { error: 'file "' + span + '" is not in the symbols index' };
    return { ref: { label: label, file: span, symbol: null, parent: null, line: 1, end: null } };
  }
  const colon = span.indexOf(':');
  if (colon !== -1 && BOOK_FILE_RE.test(span.slice(0, colon))) {
    const file = span.slice(0, colon);
    const nm = BOOK_NAME_RE.exec(span.slice(colon + 1));
    if (!symbols.files[file]) return { error: 'pinned file "' + file + '" is not in the symbols index' };
    if (!nm) return {};
    const hits = bookDefsIn(symbols, [file], nm[2], nm[1] || null);
    if (!hits.length) return { error: '"' + span + '" names no definition in ' + file };
    const hit = firstOverloadHit(hits);
    if (!hit) return { error: '"' + span + '" is ambiguous (' + hits.length + ' defs in ' + file + ')' };
    return toRef(hit);
  }
  const nm = BOOK_NAME_RE.exec(span);
  if (!nm) return {};
  const parent = nm[1] || null;
  let hits = bookDefsIn(symbols, chapterFiles, nm[2], parent);
  if (!hits.length) hits = bookDefsIn(symbols, known, nm[2], parent);
  if (!hits.length) return {};
  const hit = firstOverloadHit(hits);
  if (!hit) return { error: '"' + span + '" is ambiguous (' + hits.length + ' defs) — pin it as `file.js:' + span + '`' };
  return toRef(hit);
}

// A paragraph as segments: { t } runs of text and { ref } chips. A span that
// doesn't resolve stays in the text, backticks and all. A rationale sentence
// (see detectRationale) is wrapped as { why: { kind, cite, segs } } instead,
// its citation marker stripped from the text; `why` carries the marker
// context and the chapter's { cited, unverified, inferred } counts.
function compileBookParagraph(text, chapterFiles, symbols, note, why) {
  const segs = [];
  const pushText = function (list, t) {
    if (!t) return;
    const last = list[list.length - 1];
    if (last && last.t !== undefined) last.t += t; else list.push({ t: t });
  };
  const pushRefs = function (list, s) {
    let at = 0, m;
    BOOK_REF_RE.lastIndex = 0;
    while ((m = BOOK_REF_RE.exec(s))) {
      pushText(list, s.slice(at, m.index));
      const r = resolveBookRef(m[1], chapterFiles, symbols);
      if (r.error) note('reference ' + r.error + ' — kept as text');
      if (r.ref) list.push({ ref: r.ref }); else pushText(list, m[0]);
      at = m.index + m[0].length;
    }
    pushText(list, s.slice(at));
  };
  if (!why) {
    pushRefs(segs, text);
    return segs;
  }
  detectRationale(text).forEach(function (s) {
    if (!s.rationale) { pushRefs(segs, s.raw); return; }
    let kind = 'inferred', cite = null;
    if (s.marker) {
      const r = resolveWhyMarker(s.marker, why);
      if (r.error) note('rationale ' + r.error + ': "' + whyExcerpt(s.text) + '"');
      else { kind = r.kind; cite = r.cite; }
    } else if (!s.hedged) {
      note('rationale has no citation marker or hedge: "' + whyExcerpt(s.text) + '"');
    }
    why.counts[kind]++;
    pushText(segs, s.lead);
    const inner = [];
    pushRefs(inner, s.text);
    segs.push({ why: { kind: kind, cite: cite, segs: inner } });
  });
  return segs;
}

// ── rationale: cited versus inferred "why" sentences ──
// A sentence that states a reason must end with a citation marker — `[src:
// file:line]` (a code comment), `[rule: fragment]` (a CLAUDE.md line), `[req:
// id]` (an assignment.md requirement), `[commit: hash]` — or read as inference
// with a hedge. Cited and inferred rationale render differently, so a reader
// can see which "why" the book can back up.
const WHY_CONNECTIVE_RE = /\b(?:because|so that|in order to|the reason|which is why)\b/i;
const WHY_HEDGE_RE = /\b(?:appears to|seems to|presumably|likely|probably)\b/i;
const WHY_MARKER_OPEN_RE = /^\[(?:src|rule|req|commit):/;
const WHY_MARKER_LEAD_RE = /^\s*\[(?:src|rule|req|commit):[^\]]*\]/;
const WHY_MARKER_TAIL_RE = /([.!?]?)\s*\[(src|rule|req|commit):\s*([^\]]*?)\s*\]\s*([.!?]?)\s*$/;
const WHY_RULE_MIN = 12;
const WHY_EXCERPT_MAX = 60;

function whyExcerpt(text) {
  const s = String(text || '').trim();
  return s.length > WHY_EXCERPT_MAX ? s.slice(0, WHY_EXCERPT_MAX).trimEnd() + '…' : s;
}

// `text` cut into sentences on `.`, `?` or `!` before a space or the end,
// ignoring stops inside backticks and markers. The pieces join back into
// `text` exactly; a marker written after a sentence's stop moves back onto it.
function splitSentences(text) {
  const s = String(text || '');
  const out = [];
  let start = 0, inTick = false, inMarker = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (inMarker) { if (c === ']') inMarker = false; continue; }
    if (c === '`') { inTick = !inTick; continue; }
    if (inTick) continue;
    if (c === '[' && WHY_MARKER_OPEN_RE.test(s.slice(i, i + 8))) { inMarker = true; continue; }
    if ((c === '.' || c === '?' || c === '!') && (i + 1 === s.length || /\s/.test(s[i + 1]))) {
      out.push(s.slice(start, i + 1));
      start = i + 1;
    }
  }
  if (start < s.length) out.push(s.slice(start));
  for (let k = 1; k < out.length; k++) {
    const m = WHY_MARKER_LEAD_RE.exec(out[k]);
    if (!m) continue;
    out[k - 1] += m[0];
    out[k] = out[k].slice(m[0].length);
  }
  return out.filter(function (p) { return p !== ''; });
}

// Each sentence of `text` as { raw, lead, text, rationale, hedged, marker }:
// `raw` the sentence as written, `lead` its leading whitespace, `text` the
// rest with a trailing citation marker stripped, and `marker` that marker as
// { type, value } (or null). A sentence is rationale when, outside backticks,
// it carries one of the connectives as whole words.
function detectRationale(text) {
  return splitSentences(text).map(function (raw) {
    const lead = /^\s*/.exec(raw)[0];
    let body = raw.slice(lead.length).replace(/\s+$/, '');
    const trail = raw.slice(lead.length + body.length);
    let marker = null;
    const m = WHY_MARKER_TAIL_RE.exec(body);
    if (m) {
      marker = { type: m[2], value: m[3] };
      body = body.slice(0, m.index) + (m[1] || m[4]);
    }
    const plain = body.replace(/`[^`\n]*`/g, ' ');
    return {
      raw: raw,
      lead: lead,
      text: body + trail,
      rationale: WHY_CONNECTIVE_RE.test(plain),
      hedged: WHY_HEDGE_RE.test(plain),
      marker: marker,
    };
  });
}

function escapeRegExp(s) {
  return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Whether source line `line` of `file` holds a comment token: `//`, `/*`, a
// leading `*` or `#` in web source; `//` (and `///`) or `/*` in C#.
function isCommentLine(file, line) {
  if (/\.cs$/i.test(file)) return /\/\/|\/\*/.test(line);
  return /\/\/|\/\*/.test(line) || /^\s*[*#]/.test(line);
}

// { kind: "cited" | "unverified", cite: { type, file, line, text, label } } for
// a marker that resolves, or { error }. `ctx` holds the symbols index,
// sourceText(file), claudeMd() and assignment() (each text or null).
function resolveWhyMarker(marker, ctx) {
  const c = ctx || {};
  const type = marker && marker.type;
  const value = String((marker && marker.value) || '').trim();
  const lineOf = function (text, idx) { return text.slice(0, idx).split('\n').length; };
  if (type === 'src') {
    const colon = value.lastIndexOf(':');
    const file = colon === -1 ? value : value.slice(0, colon);
    const line = colon === -1 ? NaN : Number(value.slice(colon + 1));
    if (!Number.isInteger(line) || line < 1) return { error: 'citation "' + value + '" needs file:line' };
    if (!c.symbols || !c.symbols.files || !c.symbols.files[file]) return { error: 'citation file "' + file + '" is not in the symbols index' };
    const src = c.sourceText ? c.sourceText(file) : null;
    const lines = src === null || src === undefined ? [] : String(src).split(/\r?\n/);
    if (line > lines.length) return { error: 'citation "' + value + '" is past the end of the file' };
    if (!isCommentLine(file, lines[line - 1])) return { error: 'citation "' + value + '" does not point at a comment' };
    return { kind: 'cited', cite: { type: 'src', file: file, line: line, text: lines[line - 1].trim(), label: file.split('/').pop() + ':' + line } };
  }
  if (type === 'rule') {
    const fragment = value.replace(/^["'“”‘’]+|["'“”‘’]+$/g, '').replace(/\s+/g, ' ').trim();
    if (fragment.length < WHY_RULE_MIN) return { error: 'rule fragment "' + fragment + '" is shorter than ' + WHY_RULE_MIN + ' characters' };
    const doc = c.claudeMd ? c.claudeMd() : null;
    if (doc === null || doc === undefined) return { error: 'rule citation needs a CLAUDE.md' };
    const flat = String(doc).replace(/\s+/g, ' ');
    if (flat.indexOf(fragment) === -1) return { error: 'rule fragment "' + fragment + '" is not in CLAUDE.md' };
    const exact = String(doc).indexOf(fragment);
    return { kind: 'cited', cite: { type: 'rule', file: 'CLAUDE.md', line: exact === -1 ? null : lineOf(String(doc), exact), text: fragment, label: 'CLAUDE.md' } };
  }
  if (type === 'req') {
    if (!value) return { error: 'requirement citation has no id' };
    const doc = c.assignment ? c.assignment() : null;
    if (doc === null || doc === undefined) return { error: 'requirement "' + value + '" cited but there is no assignment.md' };
    const token = new RegExp('(^|[^\\w])' + escapeRegExp(value) + '(?![\\w])');
    const lines = String(doc).split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const l = lines[i];
      if (/^\s*(?:#{1,6}|[-*+]|\d+[.)])\s/.test(l) && token.test(l)) {
        return { kind: 'cited', cite: { type: 'req', file: 'assignment.md', line: i + 1, text: l.replace(/^\s*(?:#{1,6}|[-*+]|\d+[.)])\s+/, '').trim(), label: value } };
      }
    }
    return { error: 'requirement "' + value + '" is not a heading or list item in assignment.md' };
  }
  if (type === 'commit') {
    if (!/^[0-9a-f]{7,40}$/i.test(value)) return { error: 'commit "' + value + '" is not a 7–40 character hex hash' };
    return { kind: 'unverified', cite: { type: 'commit', file: null, line: null, text: value, label: value.slice(0, 7) } };
  }
  return { error: 'unknown citation marker "' + type + '"' };
}

// The marker context for one compile: lazy, memoised readers for source text
// and the two citable docs. `docs` values are text, null, or a function
// returning either.
function bookWhyContext(symbols, sources, docs) {
  const d = docs || {};
  const byName = {};
  (Array.isArray(sources) ? sources : []).forEach(function (s) { if (s && s.name) byName[s.name] = s.text; });
  const lazy = function (v) {
    let done = false, val = null;
    return function () {
      if (!done) { done = true; val = typeof v === 'function' ? v() : v; if (val === undefined) val = null; }
      return val;
    };
  };
  return {
    symbols: symbols,
    sourceText: function (f) { return Object.prototype.hasOwnProperty.call(byName, f) ? byName[f] : null; },
    claudeMd: lazy(d.claudeMd),
    assignment: lazy(d.assignment),
  };
}

// ── the map chapter (kind: "map") ──
// The book's table of contents for the code: the codemap areas in book order,
// under each its front-door files (most imported first) with the module's own
// purpose, and under each file the few names other files use most, each with
// an authored one-line role.
const BOOK_MAP_FILES_PER_AREA = 3;
const BOOK_MAP_SYMBOLS_PER_FILE = 3;
const BOOK_MAP_IDENT_RE = /[A-Za-z_$][\w$]*/g;

function positiveInt(n, fallback) {
  return Number.isInteger(n) && n > 0 ? n : fallback;
}

// The map's areas as [{ id, name, purpose, files }]: codemap areas in the
// order `chapters` first name them, then the rest in codemap order. Without a
// codemap, one area per top-level folder below the files' common directory,
// alphabetical, labelled by its path and with no purpose.
function mapAreas(files, areas, chapters) {
  if (Array.isArray(areas)) {
    const byId = new Map();
    areas.forEach(function (a) { if (a && a.id && !byId.has(a.id)) byId.set(a.id, a); });
    const order = [];
    (Array.isArray(chapters) ? chapters : []).forEach(function (ch) {
      if (ch && byId.has(ch.area) && order.indexOf(ch.area) === -1) order.push(ch.area);
    });
    byId.forEach(function (a, id) { if (order.indexOf(id) === -1) order.push(id); });
    return order.map(function (id) {
      const a = byId.get(id);
      return { id: id, name: a.name || id, purpose: a.purpose || null, files: Array.isArray(a.files) ? a.files : [] };
    });
  }
  const dirs = files.map(function (f) { return f.split('/').slice(0, -1); });
  let common = dirs.length ? dirs[0].slice() : [];
  dirs.forEach(function (d) {
    let k = 0;
    while (k < common.length && k < d.length && common[k] === d[k]) k++;
    common = common.slice(0, k);
  });
  const groups = new Map();
  files.forEach(function (f, i) {
    const d = dirs[i];
    const key = d.slice(0, Math.min(d.length, common.length + 1)).join('/') || '.';
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(f);
  });
  return Array.from(groups.keys()).sort().map(function (key) {
    return { id: key, name: key, purpose: null, files: groups.get(key) };
  });
}

// A csharp file's primary type: the top-level type named like the file, else
// its first top-level def.
function csharpPrimaryDef(defs, file) {
  const top = defs.filter(function (d) { return d.parent === null || d.parent === undefined; });
  const base = file.split('/').pop().replace(/\.cs$/i, '');
  return top.find(function (d) { return d.name === base; }) ||
    top.slice().sort(function (a, b) { return a.start - b.start; })[0] || null;
}

// The first `///` or `//` comment line above `line` (1-based), attributes
// skipped and doc tags stripped, or null.
function csharpPurpose(text, line) {
  const lines = String(text || '').split(/\r?\n/);
  let i = line - 2;
  while (i >= 0 && /^\s*\[/.test(lines[i])) i--;
  let top = -1;
  for (; i >= 0 && /^\s*\/\//.test(lines[i]); i--) top = i;
  if (top === -1) return null;
  for (let k = top; k < line - 1; k++) {
    const t = lines[k].replace(/^\s*\/\/\/?/, '').replace(/<[^>]*>/g, '').trim();
    if (t) return t.length > MODULE_PURPOSE_MAX ? t.slice(0, MODULE_PURPOSE_MAX).trimEnd() : t;
  }
  return null;
}

// The map hierarchy for the symbols index: [{ area: { id, name, purpose },
// files: [{ file, purpose, fanIn, fanOut, symbols: [{ key, name, parent, file,
// def, refs }] }] }], areas with no indexed file dropped.
//   - areas: mapAreas over `opts.areas` (codemap) and `opts.chapters`.
//   - files: an area's files by fan-in (other files importing it — web
//     `opts.modules` imports, else built from `sources`; csharp: files naming its
//     primary type as a whole word), then fan-out, then path; top
//     `opts.filesPerArea` (default 3). `purpose` is the module's purpose line
//     (web) or the comment above its first type (csharp), else null.
//   - symbols: a file's top-level defs — in web mode only those another file
//     imports from it — `_` names excluded, by how many other files name them
//     as a whole word, then longer name, then name; top
//     `opts.symbolsPerFile` (default 3); unreferenced names never rank. `key` is
//     the name, or `file:name` when two ranked files share it.
// `opts.mode` is 'web' | 'csharp', else inferred from .cs keys.
function rankMapSymbols(symbols, sources, opts) {
  const o = opts || {};
  const index = (symbols && symbols.files) || {};
  const files = Object.keys(index).sort();
  const perArea = positiveInt(o.filesPerArea, BOOK_MAP_FILES_PER_AREA);
  const perFile = positiveInt(o.symbolsPerFile, BOOK_MAP_SYMBOLS_PER_FILE);
  const mode = o.mode || (files.length && files.every(function (f) { return /\.cs$/.test(f); }) ? 'csharp' : 'web');
  const texts = {};
  const idents = {};
  (Array.isArray(sources) ? sources : []).forEach(function (s) {
    if (!s || !(s.name in index)) return;
    texts[s.name] = String(s.text || '');
    idents[s.name] = new Set(texts[s.name].match(BOOK_MAP_IDENT_RE) || []);
  });
  // Other indexed files that name `name` as a whole word.
  const namedBy = function (name, self) {
    return files.filter(function (g) { return g !== self && idents[g] && idents[g].has(name); });
  };

  // The names other files import from `file` (web).
  const importedNames = function (file) {
    const out = new Set();
    files.forEach(function (g) {
      const imports = index[g].imports || {};
      Object.keys(imports).forEach(function (k) { if (g !== file && imports[k].from === file) out.add(imports[k].name); });
    });
    return out;
  };

  const fanIn = {};
  const fanOut = {};
  const purpose = {};
  files.forEach(function (f) { fanIn[f] = 0; fanOut[f] = 0; purpose[f] = null; });
  if (mode === 'csharp') {
    files.forEach(function (f) {
      const primary = csharpPrimaryDef(index[f].defs, f);
      if (!primary) return;
      purpose[f] = csharpPurpose(texts[f], primary.start);
      namedBy(primary.name, f).forEach(function (g) { fanIn[f]++; fanOut[g]++; });
    });
  } else {
    const modules = Array.isArray(o.modules) ? o.modules : buildModules(Array.isArray(sources) ? sources : []);
    modules.forEach(function (m) {
      if (!(m.path in index)) return;
      purpose[m.path] = m.purpose || null;
      (m.imports || []).forEach(function (to) {
        if (to === m.path || !(to in index)) return;
        fanIn[to]++;
        fanOut[m.path]++;
      });
    });
  }

  const sections = [];
  mapAreas(files, o.areas, o.chapters).forEach(function (area) {
    const own = area.files.filter(function (f, i, all) { return f in index && all.indexOf(f) === i; });
    if (!own.length) return;
    own.sort(function (a, b) { return fanIn[b] - fanIn[a] || fanOut[b] - fanOut[a] || (a < b ? -1 : (a > b ? 1 : 0)); });
    sections.push({
      area: { id: area.id, name: area.name, purpose: area.purpose },
      files: own.slice(0, perArea).map(function (f) {
        const byName = new Map();
        const exported = mode === 'csharp' ? null : importedNames(f);
        index[f].defs.forEach(function (d) {
          if ((d.parent !== null && d.parent !== undefined) || d.kind === 'constructor' || d.name[0] === '_') return;
          if (exported && !exported.has(d.name)) return;
          if (!byName.has(d.name)) byName.set(d.name, []);
          byName.get(d.name).push(d);
        });
        const ranked = [];
        byName.forEach(function (defs, name) {
          const refs = namedBy(name, f).length;
          if (refs) ranked.push({ key: name, name: name, parent: null, file: f, def: firstOverload(defs) || defs[0], refs: refs });
        });
        ranked.sort(function (a, b) {
          return b.refs - a.refs || b.name.length - a.name.length || (a.name < b.name ? -1 : (a.name > b.name ? 1 : 0));
        });
        return { file: f, purpose: purpose[f], fanIn: fanIn[f], fanOut: fanOut[f], symbols: ranked.slice(0, perFile) };
      }),
    });
  });

  const homes = {};
  sections.forEach(function (s) { s.files.forEach(function (fr) { fr.symbols.forEach(function (r) { (homes[r.name] = homes[r.name] || new Set()).add(r.file); }); }); });
  sections.forEach(function (s) { s.files.forEach(function (fr) { fr.symbols.forEach(function (r) { if (homes[r.name].size > 1) r.key = r.file + ':' + r.name; }); }); });
  return sections;
}

function countWords(text) {
  return String(text || '').split(/\s+/).filter(Boolean).length;
}

// A map chapter's hierarchy and its flat paragraphs — one per file row
// (`[{ ref }, { t: ' — ' + purpose }]`, or just the chip) and one per symbol row
// (`[{ ref }, { t: ' — ' + role }]`), in reading order — plus the words of the
// area purposes, file purposes and roles. A file with no purpose line takes its
// role (keyed by path) when given. Every ranked symbol without a role and every
// role the map doesn't use is noted. `ctx` carries the codemap areas, the raw
// chapters, the web modules and the warn sink.
function compileBookMap(ch, symbols, sources, note, ctx) {
  const c = ctx || {};
  const roles = ch.roles && typeof ch.roles === 'object' ? ch.roles : {};
  const roleOf = function (k) { return typeof roles[k] === 'string' ? roles[k].trim() : ''; };
  if (ch.limit !== undefined && c.say) {
    c.say('Warning: codebook.json: chapter "' + ch.id + '": `limit` is ignored — use filesPerArea and symbolsPerFile');
  }
  const ranked = rankMapSymbols(symbols, sources, {
    areas: c.areas, chapters: c.chapters, modules: c.modules,
    filesPerArea: ch.filesPerArea, symbolsPerFile: ch.symbolsPerFile,
  });
  const used = new Set();
  const paragraphs = [];
  let words = 0;
  const sections = ranked.map(function (sec) {
    words += countWords(sec.area.purpose);
    return {
      area: sec.area,
      files: sec.files.map(function (fr) {
        let purpose = fr.purpose;
        if (!purpose && roleOf(fr.file)) {
          purpose = roleOf(fr.file);
          used.add(fr.file);
        }
        words += countWords(purpose);
        const ref = { label: fr.file.split('/').pop(), file: fr.file, symbol: null, parent: null, line: 1, end: null };
        paragraphs.push(purpose ? [{ ref: ref }, { t: ' — ' + purpose }] : [{ ref: ref }]);
        const syms = [];
        fr.symbols.forEach(function (r) {
          const role = roleOf(r.key);
          if (!role) { note('map symbol "' + r.key + '" has no role'); return; }
          used.add(r.key);
          words += countWords(role);
          const sref = { label: r.name, file: r.file, symbol: r.name, parent: null, line: r.def.start, end: r.def.end };
          paragraphs.push([{ ref: sref }, { t: ' — ' + role }]);
          syms.push({ ref: sref, role: role });
        });
        return { ref: ref, purpose: purpose || null, symbols: syms };
      }),
    };
  });
  Object.keys(roles).forEach(function (k) {
    if (!used.has(k)) note('map role "' + k + '" is not in the ranked set — dropped');
  });
  return { paragraphs: paragraphs, sections: sections, words: words };
}

// { version, title, chapters } compiled from a parsed codebook.json. `tours`
// is the compiled src-tours output of the same run (or null); `areas` the
// codemap areas (optional); `sources` the { name, text } list a map chapter
// ranks against and `modules` the web manifest's modules (both optional). A
// chapter is `kind: "prose"` (its `body`) or `kind: "map"` (its `roles`,
// compiled by compileBookMap into `sections` as well as paragraphs), and only
// the first chapter may be the map. `docs` is { claudeMd, assignment } — each
// text, null, or a function returning either, read only when a rationale
// marker cites it. Each chapter counts its rationale as `rationale`.
function compileBook(doc, symbols, tours, areas, warn, sources, modules, docs) {
  const say = warn || console.warn;
  const index = symbols && symbols.files ? symbols : { files: {} };
  const whyCtx = bookWhyContext(index, sources, docs);
  const tourById = {};
  ((tours && Array.isArray(tours.tours)) ? tours.tours : []).forEach(function (t) { tourById[t.id] = t; });
  const areaIds = Array.isArray(areas) ? new Set(areas.map(function (a) { return a && a.id; })) : null;
  const raw = ((doc && Array.isArray(doc.chapters)) ? doc.chapters : []).filter(function (ch, i) {
    if (ch && typeof ch.id === 'string' && ch.id) return true;
    say('Warning: codebook.json: chapter ' + (i + 1) + ' has no id — chapter dropped');
    return false;
  });
  const chapters = [];
  raw.forEach(function (ch) {
    const warnings = [];
    const note = function (msg) {
      warnings.push(msg);
      say('Warning: codebook.json: chapter "' + ch.id + '": ' + msg);
    };
    const files = (Array.isArray(ch.files) ? ch.files : []).filter(function (f) {
      if (index.files[f]) return true;
      note('file "' + f + '" is not in the symbols index');
      return false;
    });
    const tourRefs = [];
    (Array.isArray(ch.tours) ? ch.tours : []).forEach(function (id) {
      const t = tourById[id];
      if (t) tourRefs.push({ id: t.id, title: t.title, steps: t.steps.length });
      else note('tour "' + id + '" is not in the compiled tours');
    });
    let area = ch.area === undefined ? null : ch.area;
    if (area !== null && areaIds && !areaIds.has(area)) {
      note('area "' + area + '" is not in codemap.json');
      area = null;
    }
    let ahead = null;
    if (ch.ahead && typeof ch.ahead === 'object') {
      const target = raw.find(function (c) { return c.id === ch.ahead.chapter; });
      if (target) ahead = { chapter: target.id, title: target.title, note: ch.ahead.note || '', promises: Array.isArray(ch.ahead.promises) ? ch.ahead.promises.filter(function (p) { return typeof p === 'string' && p.trim(); }) : [] };
      else note('ahead chapter "' + ch.ahead.chapter + '" does not exist — dropped');
    }
    const kind = ch.kind === 'map' ? 'map' : 'prose';
    const counts = { cited: 0, unverified: 0, inferred: 0 };
    let paragraphs, words, sections;
    if (kind === 'map') {
      if (ch !== raw[0]) note('the map chapter must be the first chapter');
      const map = compileBookMap(ch, index, sources, note, { areas: areas, chapters: raw, modules: modules, say: say });
      paragraphs = map.paragraphs;
      sections = map.sections;
      words = map.words;
    } else {
      const body = (Array.isArray(ch.body) ? ch.body : []).filter(function (p) { return typeof p === 'string' && p.trim(); });
      const why = Object.assign({ counts: counts }, whyCtx);
      paragraphs = body.map(function (p) { return compileBookParagraph(p, files, index, note, why); });
      words = body.reduce(function (n, p) { return n + p.split(/\s+/).filter(Boolean).length; }, 0);
    }
    if (!paragraphs.length) {
      say('Warning: codebook.json: chapter "' + ch.id + '" has no paragraphs — chapter dropped');
      return;
    }
    const chapter = {
      id: ch.id,
      index: chapters.length + 1,
      kind: kind,
      title: ch.title,
      area: area,
      files: files,
      tours: tourRefs,
      paragraphs: paragraphs,
      ahead: ahead,
      minutes: Math.max(1, Math.round(words / BOOK_WORDS_PER_MINUTE)),
      rationale: counts,
      stale: warnings.length > 0,
      warnings: warnings,
    };
    if (sections) chapter.sections = sections;
    chapters.push(chapter);
  });
  // An ahead link to a chapter dropped for having no paragraphs goes too.
  chapters.forEach(function (c) {
    if (c.ahead && !chapters.some(function (o) { return o.id === c.ahead.chapter; })) {
      const msg = 'ahead chapter "' + c.ahead.chapter + '" was dropped — link dropped';
      say('Warning: codebook.json: chapter "' + c.id + '": ' + msg);
      c.warnings.push(msg);
      c.stale = true;
      c.ahead = null;
    }
  });
  validateBookPromises(chapters, index, function (c, msg) {
    say('Warning: codebook.json: chapter "' + c.id + '": ' + msg);
    c.warnings.push(msg);
    c.stale = true;
  });
  // Drift: each chapter's code fingerprint against the one stored at the last
  // --write-fingerprints run. Needs the source text, so only with `sources`.
  const fingerprints = {};
  const fp = Array.isArray(sources) ? bookFingerprintContext(index, sources) : null;
  chapters.forEach(function (c) {
    c.drift = [];
    if (!fp) return;
    const current = bookChapterFingerprint(c, fp);
    fingerprints[c.id] = current;
    const src = raw.find(function (r) { return r.id === c.id; });
    const stored = src && src.fingerprint && typeof src.fingerprint === 'object' ? src.fingerprint : null;
    if (!stored) return;
    Object.keys(current).forEach(function (key) {
      if (typeof stored[key] !== 'string' || stored[key] === current[key]) return;
      const was = stored[key].split('.'), now = current[key].split('.');
      const body = was.length !== 2 || was[0] !== now[0];
      const importers = was.length !== 2 || was[1] !== now[1];
      const reason = body && importers ? 'both' : (body ? 'body' : 'importers');
      c.drift.push({ ref: key, reason: reason });
      const msg = 'drift: ' + bookFingerprintLabel(key) + ' ' + BOOK_DRIFT_TEXT[reason];
      say('Warning: codebook.json: chapter "' + c.id + '": ' + msg);
      c.warnings.push(msg);
      c.stale = true;
    });
  });
  const book = { version: BOOK_VERSION, title: (doc && doc.title) || '', chapters: chapters };
  // Not serialized into src-book.json — read by writeBookFingerprints.
  Object.defineProperty(book, 'fingerprints', { value: fingerprints, enumerable: false });
  return book;
}

// ── drift: a chapter's code fingerprint ──
// A chapter keeps resolving while the code it describes is rewritten, so each
// one also stores `fingerprint: { key: "<body hash>.<importers hash>" }` over
// its distinct references (paragraph chips and kept promises). The key is
// `file:symbol` (`file:Parent.symbol` under a parent) or the bare file for a
// file chip. The body is the def's lines (a file chip: its purpose line),
// whitespace-normalised; importers are the other files whose imports bind the
// name (web) or that name it as a whole word (csharp). Each half is the first
// 16 hex chars of a sha1, so a mismatch says which of the two changed.
const BOOK_DRIFT_TEXT = { body: 'body changed', importers: 'importers changed', both: 'body and importers changed' };

function bookHash(text) {
  return require('crypto').createHash('sha1').update(text).digest('hex').slice(0, 16);
}

function bookFingerprintLabel(key) {
  const colon = key.indexOf(':');
  return colon === -1 ? key : key.slice(colon + 1);
}

// The source lines and identifier sets a chapter fingerprint reads, built once.
function bookFingerprintContext(symbols, sources) {
  const text = {};
  sources.forEach(function (s) { if (s && s.name) text[s.name] = String(s.text || ''); });
  const lines = {}, words = {};
  return {
    symbols: symbols,
    files: Object.keys(symbols.files).sort(),
    text: function (f) { return Object.prototype.hasOwnProperty.call(text, f) ? text[f] : ''; },
    lines: function (f) { return lines[f] || (lines[f] = this.text(f).split(/\r?\n/)); },
    words: function (f) { return words[f] || (words[f] = new Set(this.text(f).match(/[A-Za-z_$][\w$]*/g) || [])); },
  };
}

// { key: hash } over chapter `c`'s distinct references, keys sorted.
function bookChapterFingerprint(c, ctx) {
  const refs = [];
  (c.paragraphs || []).forEach(function (segs) { refs.push.apply(refs, bookParagraphRefs(segs)); });
  ((c.ahead && c.ahead.promises) || []).forEach(function (p) { if (p && p.ref) refs.push(p.ref); });
  const out = {};
  refs.forEach(function (r) {
    const key = r.symbol ? r.file + ':' + (r.parent ? r.parent + '.' : '') + r.symbol : r.file;
    if (!(key in out)) out[key] = bookRefHash(r, ctx);
  });
  const sorted = {};
  Object.keys(out).sort().forEach(function (k) { sorted[k] = out[k]; });
  return sorted;
}

function bookRefHash(r, ctx) {
  const cs = /\.cs$/.test(r.file);
  let body, name;
  if (r.symbol) {
    body = ctx.lines(r.file).slice(r.line - 1, r.end || r.line).join('\n');
    // A member is bound through its parent in web imports; a C# constructor
    // is named by its type.
    name = cs ? (r.symbol === 'constructor' ? r.parent : r.symbol) : (r.parent || r.symbol);
  } else if (cs) {
    const entry = ctx.symbols.files[r.file];
    const primary = csharpPrimaryDef(entry ? entry.defs : [], r.file);
    body = primary ? csharpPurpose(ctx.text(r.file), primary.start) || '' : '';
    name = primary ? primary.name : null;
  } else {
    body = extractPurpose(ctx.text(r.file)) || '';
    name = null;
  }
  const importers = ctx.files.filter(function (g) {
    if (g === r.file) return false;
    if (cs) return !!name && ctx.words(g).has(name);
    const imports = ctx.symbols.files[g].imports || {};
    return Object.keys(imports).some(function (k) {
      const b = imports[k];
      return b.from === r.file && (name === null || b.name === name || b.name === '*');
    });
  });
  return bookHash(String(body).replace(/\s+/g, ' ').trim()) + '.' + bookHash(importers.join('\n'));
}

// The `ref` segments of a compiled paragraph, rationale wraps included.
function bookParagraphRefs(segs) {
  const out = [];
  segs.forEach(function (s) {
    if (s.ref) out.push(s.ref);
    else if (s.why) out.push.apply(out, bookParagraphRefs(s.why.segs));
  });
  return out;
}

// Second pass over the compiled chapters: each `ahead.promises` string
// resolves against the target chapter's files (then the whole index) and must
// be a chip somewhere in the target's paragraphs. Kept promises become
// { ref, paraIndex }, the first target paragraph that references the symbol;
// a broken one is dropped and `note(chapter, msg)` flags the source chapter,
// since its note is what became untrue.
function validateBookPromises(chapters, symbols, note) {
  const same = function (a, b) { return a.file === b.file && a.symbol === b.symbol && a.parent === b.parent; };
  chapters.forEach(function (c) {
    if (!c.ahead) return;
    const target = chapters.find(function (o) { return o.id === c.ahead.chapter; });
    const promises = [];
    (c.ahead.promises || []).forEach(function (p) {
      if (typeof p !== 'string') return;
      const r = resolveBookRef(p, target.files, symbols);
      if (!r.ref) { note(c, 'ahead promises "' + p + '" which does not resolve'); return; }
      const paraIndex = target.paragraphs.findIndex(function (segs) {
        return bookParagraphRefs(segs).some(function (ref) { return same(ref, r.ref); });
      });
      if (paraIndex === -1) { note(c, 'ahead promises "' + p + '" but chapter "' + target.id + '" never references it'); return; }
      promises.push({ ref: r.ref, paraIndex: paraIndex });
    });
    c.ahead.promises = promises;
  });
}

// The compiled book for the web source under `srcDir`, or null when
// codebook.json is absent (nothing is written then).
function buildWebBook(opts) {
  const o = opts || {};
  const root = o.srcDir || srcDir;
  const doc = readJsonFile(o.bookPath || path.resolve(root, '..', 'codebook.json'));
  if (!doc) return null;
  // `sources` overrides the src/ read — csharp mode passes its .cs list.
  const sources = o.sources || readWebSources(root).sources;
  const symbols = o.symbols || buildSymbols(sources);
  const tours = o.tours !== undefined ? o.tours : buildWebTours(Object.assign({}, o, { symbols: symbols, sources: sources }));
  const areas = readCodemapAreas(o.codemapPath || path.resolve(root, '..', 'codemap.json'));
  const modules = o.modules || (o.sources ? undefined : buildModules(sources));
  const docRoot = o.docRoot || bookDocRoot(path.resolve(root, '..'));
  const docs = o.docs || {
    claudeMd: function () { return readTextFile(path.join(docRoot, 'CLAUDE.md')); },
    assignment: function () { return readTextFile(path.join(docRoot, 'assignment.md')); },
  };
  return compileBook(doc, symbols, tours, areas, o.warn, sources, modules, docs);
}

function readTextFile(file) {
  try { return fs.readFileSync(file, 'utf8'); } catch (e) { return null; }
}

// The folder a rationale marker's CLAUDE.md and assignment.md are read from:
// `start` (the project folder) or the nearest ancestor holding a CLAUDE.md,
// stopping at the git root — a web project often sits a level below it.
function bookDocRoot(start) {
  let dir = start;
  for (let k = 0; k < 3; k++) {
    if (fs.existsSync(path.join(dir, 'CLAUDE.md'))) return dir;
    if (fs.existsSync(path.join(dir, '.git'))) break;
    const up = path.dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  return start;
}

// Rewrites every chapter's `fingerprint` in codebook.json from the current
// source, splicing only that key's text so every other byte stays as
// committed (its hand-kept inline arrays included); returns true when the
// file changed. Nothing happens without a codebook.json.
function writeBookFingerprints(opts) {
  const o = opts || {};
  const root = o.srcDir || srcDir;
  const bookPath = o.bookPath || path.resolve(root, '..', 'codebook.json');
  const before = readTextFile(bookPath);
  if (before === null) return false;
  const book = buildWebBook(Object.assign({}, o, { bookPath: bookPath, warn: function () {} }));
  const top = jsonSpans(before, skipJsonWs(before, 0));
  const list = top.members && top.members.find(function (m) { return m.key === 'chapters'; });
  if (!book || !list || !list.value.items) return false;
  let after = before;
  // Back to front, so earlier offsets stay valid as later text changes length.
  list.value.items.slice().reverse().forEach(function (ch) {
    const idMember = ch.members && ch.members.find(function (m) { return m.key === 'id'; });
    const id = idMember ? JSON.parse(before.slice(idMember.value.start, idMember.value.end)) : null;
    if (!ch.members.length || !Object.prototype.hasOwnProperty.call(book.fingerprints, id)) return;
    const first = ch.members[0];
    const indent = /[ \t]*$/.exec(before.slice(0, first.start))[0];
    const keys = Object.keys(book.fingerprints[id]);
    const value = keys.length
      ? '{\n' + keys.map(function (k) { return indent + '  ' + JSON.stringify(k) + ': ' + JSON.stringify(book.fingerprints[id][k]); }).join(',\n') + '\n' + indent + '}'
      : '{}';
    const own = ch.members.find(function (m) { return m.key === 'fingerprint'; });
    if (own) after = after.slice(0, own.value.start) + value + after.slice(own.value.end);
    else {
      const last = ch.members[ch.members.length - 1];
      after = after.slice(0, last.value.end) + ',\n' + indent + '"fingerprint": ' + value + after.slice(last.value.end);
    }
  });
  if (after === before) return false;
  fs.writeFileSync(bookPath, after);
  return true;
}

function skipJsonWs(text, i) { while (i < text.length && /\s/.test(text[i])) i++; return i; }

// The JSON value starting at `i` as { start, end } offsets, with `members:
// [{ key, start, value }]` for an object and `items` for an array — enough to
// splice one key without re-serialising its neighbours. Assumes valid JSON.
function jsonSpans(text, i) {
  const c = text[i];
  if (c === '"') {
    let k = i + 1;
    while (text[k] !== '"') k += text[k] === '\\' ? 2 : 1;
    return { start: i, end: k + 1 };
  }
  if (c === '{' || c === '[') {
    const node = { start: i };
    if (c === '{') node.members = []; else node.items = [];
    let k = skipJsonWs(text, i + 1);
    while (text[k] !== (c === '{' ? '}' : ']')) {
      if (c === '{') {
        const key = jsonSpans(text, k);
        const value = jsonSpans(text, skipJsonWs(text, skipJsonWs(text, key.end) + 1));
        node.members.push({ key: JSON.parse(text.slice(key.start, key.end)), start: key.start, value: value });
        k = value.end;
      } else {
        const item = jsonSpans(text, k);
        node.items.push(item);
        k = item.end;
      }
      k = skipJsonWs(text, k);
      if (text[k] === ',') k = skipJsonWs(text, k + 1);
    }
    node.end = k + 1;
    return node;
  }
  const lit = /^-?[\w.+-]+/.exec(text.slice(i));
  return { start: i, end: i + lit[0].length };
}

// Writes src-book.json into `outDir` when codebook.json exists; returns the
// compiled book, or null when nothing was written.
function writeWebBook(opts) {
  const o = opts || {};
  const book = buildWebBook(o);
  if (!book) return null;
  fs.writeFileSync(path.join(o.outDir || outDir, 'src-book.json'), JSON.stringify(book));
  return book;
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
const CS_KW_NAME = { 'if':1,'for':1,'foreach':1,'while':1,'switch':1,'using':1,'lock':1,'catch':1,'fixed':1,'return':1,'throw':1,'yield':1,'await':1,'new':1,'sizeof':1,'typeof':1,'nameof':1,'default':1,'checked':1,'unchecked':1,'when':1,'do':1,'else':1,'in':1,'is':1,'as':1,'where':1,'select':1,'from':1 };
// Accessor keywords: legal method names (CS_METHOD_RE needs a return type and
// parameter list, which accessors never have), but `protected set => …` would
// read as a property named `set`, so the property pass still skips them.
const CS_ACCESSOR_KW = { 'get':1,'set':1,'init':1,'add':1,'remove':1 };
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
  const braces = braceMap(src);
  const lastLine = lineAt(src.length);
  let m;

  // Line of the `}` closing the block opened at `open`; the file's last line
  // when it never closes.
  function blockEnd(open) {
    const close = braces.get(open);
    return close === undefined ? lastLine : lineAt(close);
  }
  // A member's end from the token that closed its match: `{` opens a block
  // body; `=>` (expression-bodied) and `;` (abstract / interface) end on the
  // member's own line.
  function memberEnd(m, at) {
    const last = m.indices[0][1] - 1;
    return src[last] === '{' ? blockEnd(last) : lineAt(at);
  }

  // 1. type declarations (sorted by position, capped per file)
  const decls = [];
  CS_TYPE_DECL_RE.lastIndex = 0;
  while ((m = CS_TYPE_DECL_RE.exec(src)) !== null) {
    if (decls.length >= CS_MAX_TYPES_PER_FILE) break;
    const at = m.indices[2][0];
    // The body opens at the first `{` after the name; a `;` first means a
    // body-less declaration (`record Point(int X, int Y);`) on its own line.
    const tail = /[{;]/.exec(src.slice(m.indices[2][1]));
    const open = tail && tail[0] === '{' ? m.indices[2][1] + tail.index : -1;
    decls.push({ name: m[2], kind: m[1], file: relPath, line: lineAt(at), end: open < 0 ? lineAt(at) : blockEnd(open), index: at, members: [] });
  }
  if (!decls.length) return [];
  decls.sort(function (a, b) { return a.index - b.index; });

  function ownerFor(idx) {
    let chosen = null;
    for (let k = 0; k < decls.length; k++) { if (decls[k].index <= idx) chosen = decls[k]; else break; }
    return chosen;
  }
  const seen = {};
  function addMember(at, kind, name, signature, end) {
    const owner = ownerFor(at);
    if (!owner || owner.members.length >= CS_MAX_MEMBERS_PER_TYPE) return;
    const key = owner.name + '|' + name + '|' + signature;
    if (seen[key]) return;
    seen[key] = 1;
    owner.members.push({ name: name, kind: kind, signature: signature, line: lineAt(at), end: end });
  }

  // 2. methods — return type is mandatory, which excludes bare calls like
  // Foo(); and control flow like if (...) (no name between keyword and paren).
  CS_METHOD_RE.lastIndex = 0;
  while ((m = CS_METHOD_RE.exec(src)) !== null) {
    const name = m[2];
    if (CS_KW_NAME[name] || CS_TYPE_KW[name]) continue;
    const rt = csClean(m[1]);
    if (!rt || CS_RT_STMT[rt.split(' ').pop()]) continue;
    addMember(m.indices[2][0], 'method', name, name + '(' + csClean(m[3]) + ')', memberEnd(m, m.indices[2][0]));
  }

  // 3. constructors — name matches a type declared in this file.
  const names = decls.map(function (d) { return d.name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); });
  const uniq = names.filter(function (v, k) { return names.indexOf(v) === k; });
  if (uniq.length) {
    const ctorRe = new RegExp('(?:^|[\\n;{}])[ \\t]*(?:(?:public|private|protected|internal|static)[ \\t]+)*\\b(' + uniq.join('|') + ')[ \\t]*\\(([^()]*)\\)[ \\t\\r\\n]*(?::[^={;\\n]+)?[ \\t\\r\\n]*\\{', 'gd');
    while ((m = ctorRe.exec(src)) !== null) {
      addMember(m.indices[1][0], 'method', m[1], m[1] + '(' + csClean(m[2]) + ')', memberEnd(m, m.indices[1][0]));
    }
  }

  // 4. properties — auto / full / expression-bodied. The get|set|init lookahead
  // and the no-paren shape exclude fields and methods respectively.
  CS_PROP_RE.lastIndex = 0;
  while ((m = CS_PROP_RE.exec(src)) !== null) {
    const name = m[2];
    if (CS_KW_NAME[name] || CS_ACCESSOR_KW[name]) continue;
    const type = csClean(m[1]);
    const tLast = type.split(' ').pop();
    if (!type || CS_TYPE_KW[tLast] || CS_RT_STMT[tLast]) continue;
    addMember(m.indices[2][0], 'property', name, name + ' : ' + type, memberEnd(m, m.indices[2][0]));
  }

  return decls.map(function (d) {
    d.members.sort(function (a, b) { return a.line - b.line; });
    return { name: d.name, kind: d.kind, file: d.file, line: d.line, end: d.end, members: d.members };
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

// The { name, text } list of the .cs files buildCsharpManifest inventories,
// `name` repo-root-relative and sorted. `opts.repoRoot` / `opts.srcRoot`
// override the script's root and MANIFEST_SRC_ROOT (for tests).
function readCsharpSources(opts) {
  const o = opts || {};
  const root = o.repoRoot || repoRoot;
  const scope = o.srcRoot !== undefined ? o.srcRoot : process.env.MANIFEST_SRC_ROOT;
  const walkRoot = scope ? path.resolve(root, scope) : root;
  const rel = function (p) { return path.relative(root, p).split(path.sep).join('/'); };
  const out = [];
  walkCs(walkRoot).forEach(function (abs) {
    try { out.push({ name: rel(abs), text: fs.readFileSync(abs, 'utf8') }); } catch (e) { /* unreadable — skip */ }
  });
  return out.sort(function (a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0); });
}

// The scanCsharpTypes outline of one file as symbols-index defs: one per type
// and one per member, each parented by the innermost type whose lines enclose
// it (a nested type's members included). A constructor is named `constructor`,
// as in the web index, so a bare type name never collides with it.
function csharpDefs(text, name) {
  const types = scanCsharpTypes(text, name);
  // Innermost type enclosing [start, end], other than `self`; `fallback` wins
  // ties (the scanner's own owner for a member).
  function enclosing(start, end, self, fallback) {
    let best = null;
    types.forEach(function (t) {
      if (t === self || t.line > start || t.end < end) return;
      if (self && t.line === self.line && t.end === self.end) return;
      if (!best || t.line > best.line || (t.line === best.line && t.end < best.end) ||
          (t.line === best.line && t.end === best.end && t === fallback)) best = t;
    });
    return best || fallback || null;
  }
  const defs = [];
  types.forEach(function (t) {
    const outer = enclosing(t.line, t.end, t, null);
    defs.push({ name: t.name, kind: t.kind, start: t.line, end: t.end, parent: outer ? outer.name : null });
    t.members.forEach(function (mm) {
      const owner = enclosing(mm.line, mm.end, null, t);
      const ctor = mm.kind === 'method' && mm.name === owner.name;
      defs.push({ name: ctor ? 'constructor' : mm.name, kind: ctor ? 'constructor' : mm.kind, start: mm.line, end: mm.end, parent: owner.name });
    });
  });
  return defs.sort(function (a, b) { return a.start - b.start || b.end - a.end; });
}

// The csharp counterpart of buildWebSymbols: the same { version, files }
// index, keyed by repo-root-relative .cs path. `opts.sources` skips the walk.
function buildCsharpSymbols(opts) {
  const o = opts || {};
  const sources = o.sources || readCsharpSources(o);
  const files = {};
  sources.slice().sort(function (a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0); })
    .forEach(function (s) { files[s.name] = { defs: csharpDefs(s.text, s.name), imports: {} }; });
  return { version: SYMBOLS_VERSION, files: files };
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

function langMode() {
  if (LANG === 'csharp' || LANG === 'cs' || LANG === 'dotnet') return 'csharp';
  if (LANG === 'sql' || LANG === 'postgres' || LANG === 'postgresql') return 'sql';
  if (LANG === 'doc' || LANG === 'docs' || LANG === 'markdown') return 'doc';
  return 'web';
}

function buildManifest() {
  const mode = langMode();
  let base;
  if (mode === 'csharp') base = buildCsharpManifest();
  else if (mode === 'sql') base = buildSqlManifest();
  else if (mode === 'doc') base = buildDocManifest();
  else base = buildWebManifest();
  return finalize(base);
}

module.exports = { scanRegions: scanRegions, parseImports: parseImports, extractPurpose: extractPurpose, buildModules: buildModules, codemapWarnings: codemapWarnings, buildWebManifest: buildWebManifest, scanJsDefs: scanJsDefs, parseImportBindings: parseImportBindings, buildSymbols: buildSymbols, buildWebSymbols: buildWebSymbols, compileTours: compileTours, buildWebTours: buildWebTours, writeWebTours: writeWebTours, compileBook: compileBook, validateBookPromises: validateBookPromises, detectRationale: detectRationale, resolveWhyMarker: resolveWhyMarker, rankMapSymbols: rankMapSymbols, buildWebBook: buildWebBook, writeWebBook: writeWebBook, writeBookFingerprints: writeBookFingerprints, scanCsharpTypes: scanCsharpTypes, readCsharpSources: readCsharpSources, buildCsharpSymbols: buildCsharpSymbols, prettify: prettify, buildManifest: buildManifest, walkCs: walkCs, walkSql: walkSql, walkDoc: walkDoc };

if (require.main === module) {
  const manifest = buildManifest();
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, 'src-manifest.json'), JSON.stringify(manifest, null, 2));
  console.log(
    'src-manifest.json [' + LANG + '] written to ' + outDirName + '/ —',
    manifest.files.length, 'files,',
    manifest.regions.length, 'regions,',
    (manifest.types ? manifest.types.length : 0), 'types,',
    (manifest.tables ? manifest.tables.length : 0), 'tables,',
    (manifest.modules ? manifest.modules.length : 0), 'modules,',
    (manifest.areas ? manifest.areas.length : 0), 'areas, hasDom=' + manifest.hasDom + ', lens=' + manifest.lens
  );
  // The definitions index (web and csharp only) is never timestamped, so it
  // only changes when the source does. Tours and the book compile against the
  // mode's own sources, so step and chapter paths match the index keys.
  const mode = langMode();
  if (mode === 'web' || mode === 'csharp') {
    const sources = mode === 'csharp' ? readCsharpSources() : undefined;
    const symbols = mode === 'csharp' ? buildCsharpSymbols({ sources: sources }) : buildWebSymbols();
    const json = JSON.stringify(symbols);
    fs.writeFileSync(path.join(outDir, 'src-symbols.json'), json);
    const defCount = Object.keys(symbols.files).reduce(function (n, f) { return n + symbols.files[f].defs.length; }, 0);
    console.log('src-symbols.json written to ' + outDirName + '/ —', defCount, 'defs,', (Buffer.byteLength(json) / 1024).toFixed(1) + ' KB');
    const tours = writeWebTours({ symbols: symbols, sources: sources });
    if (tours) {
      const stepCount = tours.tours.reduce(function (n, t) { return n + t.steps.length; }, 0);
      console.log('src-tours.json written to ' + outDirName + '/ —', tours.tours.length, 'tours,', stepCount, 'steps');
    }
    // The book routine's last step: store each chapter's code fingerprint so
    // the next compile can tell when that code drifts. Never on a normal run.
    if (process.argv.indexOf('--write-fingerprints') !== -1 || process.env.MANIFEST_WRITE_FINGERPRINTS === '1') {
      const changed = writeBookFingerprints({ symbols: symbols, tours: tours, sources: sources, modules: manifest.modules });
      console.log('codebook.json fingerprints ' + (changed ? 'written' : 'unchanged'));
    }
    const book = writeWebBook({ symbols: symbols, tours: tours, sources: sources, modules: manifest.modules });
    if (book) {
      const refCount = book.chapters.reduce(function (n, c) {
        return n + c.paragraphs.reduce(function (k, p) { return k + p.filter(function (s) { return s.ref; }).length; }, 0);
      }, 0);
      const staleCount = book.chapters.filter(function (c) { return c.stale; }).length;
      const driftCount = book.chapters.filter(function (c) { return c.drift.length; }).length;
      console.log('src-book.json written to ' + outDirName + '/ —', book.chapters.length, 'chapters,', refCount, 'references,', staleCount, 'stale,', driftCount, 'drift');
    }
    // The map hierarchy a map chapter needs roles for, on stderr: each area,
    // its front-door files with fan-in / fan-out, and their ranked symbols
    // keyed as `roles` must key them.
    if (process.argv.indexOf('--print-map-candidates') !== -1 || process.env.MANIFEST_PRINT_MAP === '1') {
      const doc = readJsonFile(path.resolve(srcDir, '..', 'codebook.json'));
      const chapters = doc && Array.isArray(doc.chapters) ? doc.chapters : [];
      const mapCh = chapters.find(function (c) { return c && c.kind === 'map'; }) || {};
      const sections = rankMapSymbols(symbols, mode === 'csharp' ? sources : readWebSources(srcDir).sources, {
        areas: readCodemapAreas(path.resolve(srcDir, '..', 'codemap.json')), chapters: chapters, modules: manifest.modules,
        filesPerArea: mapCh.filesPerArea, symbolsPerFile: mapCh.symbolsPerFile,
      });
      const symbolCount = sections.reduce(function (n, s) { return n + s.files.reduce(function (k, f) { return k + f.symbols.length; }, 0); }, 0);
      console.error('Map candidates (' + symbolCount + ' symbols in ' + sections.length + ' areas) — area, file  fanIn  fanOut  [purpose], key  refs:');
      sections.forEach(function (s) {
        console.error(s.area.name + (s.area.purpose ? ' — ' + s.area.purpose : ''));
        s.files.forEach(function (f) {
          console.error('  ' + f.file + '  ' + f.fanIn + '  ' + f.fanOut + (f.purpose ? '  ' + f.purpose : '  (no purpose — role keyed by path)'));
          f.symbols.forEach(function (r) { console.error('    ' + r.key + '  ' + r.refs); });
        });
      });
    }
  }
}
