// Build helper — writes the current source inventory to src-manifest.json so
// the in-app Claude assistant's Worker can fetch an always-current file list,
// and the dashboard's Structure tab can render a Code lens (the file list) and
// a UI lens (the `regions` map below).
//
// ─────────────────────────────────────────────────────────────────
// TEMPLATE INSTANTIATION NOTES
// Two identical copies ship in the template: gen-src-manifest.js and
// gen-src-manifest.cjs. Both are plain CommonJS. Keep the .cjs when the repo's
// package.json declares "type": "module" (Node would otherwise treat a .js as
// ESM and the require() calls would fail); keep the .js otherwise. Onboarding
// keeps the matching one and deletes the other.
//
// Parameterized by two environment variables so one script serves every shape:
//
//   MANIFEST_OUT_DIR   — where to write src-manifest.json, relative to the repo
//                        root. Default "dist" (build-pipeline projects whose
//                        build output is published). Set "." for served-from-
//                        source projects (served straight from the repo root on
//                        main — no build, no dist/).
//
//   MANIFEST_DETERMINISTIC — "true" omits the volatile generatedAt/sha fields so
//                        the manifest only changes when the file LIST or regions
//                        change. Used by served-from-source projects whose
//                        workflow commits the manifest back to the branch.
//
// The onboard script sets these from the detected shape. A repo with no src/
// (repo-only / SQL / docs shapes) is handled gracefully — empty files, empty
// regions, hasDom:false — so the same script is safe to run anywhere.
// ─────────────────────────────────────────────────────────────────

const fs = require('fs');
const path = require('path');

const srcDir = path.resolve(__dirname, '..', 'src');

const outDirName = process.env.MANIFEST_OUT_DIR || 'dist';
const outDir = path.resolve(__dirname, '..', outDirName);

const SRC_RE = /\.(?:jsx?|tsx?|css|html?)$/;   // file list (Code lens)
const SCAN_RE = /\.(?:jsx?|tsx?|html?)$/;       // handle scan (UI lens) — markup + JS, not CSS

// A repo may have no src/ (repo-only / SQL / docs). Don't throw — emit empties.
let files = [];
try {
  files = fs.readdirSync(srcDir).filter((f) => SRC_RE.test(f)).sort();
} catch (e) {
  files = [];
}

// ── UI region scan ──────────────────────────────────────────────
// Extract the app's UI handles so the Structure tab's UI lens can show a
// published map (it can't walk a live DOM for a repo that isn't running). The
// scan is deliberately approximate: regex over source text, not a parsed AST.
// It covers both idioms the template's projects use — vanilla-JS id assignments
// (el.id = '…', { id: '…' }) and JSX/HTML attributes (id="…", class/className
// ="…", data-region="…") — with data-region as the universal, intentional
// opt-in. `file` mirrors the basenames in `files` so the tab can cross-link a
// region back to its file in the Code lens.

function isName(s) {
  return /^[A-Za-z_][\w-]*$/.test(s);
}
function prettify(token) {
  const bare = token.replace(/^[.#]/, '').replace(/[-_]+/g, ' ').trim();
  return bare ? bare.charAt(0).toUpperCase() + bare.slice(1) : token;
}
function lineOf(text, index) {
  return text.slice(0, index).split('\n').length;
}
function firstToken(value) {
  return String(value).trim().split(/\s+/)[0] || '';
}

// [regex, kind] — kind decides how the captured value becomes a selector.
const PATTERNS = [
  [/\bdata-region\s*=\s*["']([^"']+)["']/g, 'region'],
  [/\.id\s*=\s*["']([^"']+)["']/g, 'id'],                 // el.id = 'foo'
  [/(?<![-\w])id\s*:\s*["']([^"']+)["']/g, 'id'],         // { id: 'foo' }
  [/(?<![-\w])id\s*=\s*["']([^"']+)["']/g, 'id'],         // id="foo"
  [/\bclassName\s*=\s*["']([^"']+)["']/g, 'class'],
  [/\bclassName\s*=\s*\{\s*["'`]([^"'`]+)["'`]\s*\}/g, 'class'],
  [/(?<![-\w])class\s*=\s*["']([^"']+)["']/g, 'class'],   // plain HTML class="…"
];

const bySelector = new Map();

files.filter((f) => SCAN_RE.test(f)).forEach((name) => {
  let text = '';
  try { text = fs.readFileSync(path.join(srcDir, name), 'utf8'); } catch (e) { return; }
  PATTERNS.forEach(([re, kind]) => {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(text)) !== null) {
      const raw = m[1];
      let selector;
      let label;
      if (kind === 'region') {
        const value = raw.trim();
        if (!value) continue;
        selector = '[data-region="' + value + '"]';
        label = value;
      } else if (kind === 'id') {
        if (!isName(raw)) continue;
        selector = '#' + raw;
        label = prettify(selector);
      } else {
        const tok = firstToken(raw);
        if (!isName(tok)) continue;
        selector = '.' + tok;
        label = prettify(selector);
      }
      if (!bySelector.has(selector)) {
        bySelector.set(selector, { selector, label, file: name, line: lineOf(text, m.index) });
      }
    }
  });
});

const regions = Array.from(bySelector.values()).sort((a, b) =>
  a.selector.localeCompare(b.selector)
);

// hasDom: true when the repo ships any web source (markup/style/script), even
// with no named handles — lets the Structure tab tell a DOM-less repo ("no UI
// surface") apart from a web repo with an empty map.
const hasDom = files.some((f) => SRC_RE.test(f));

const deterministic = process.env.MANIFEST_DETERMINISTIC === 'true';
const manifest = deterministic
  ? { files, hasDom, regions }
  : { generatedAt: new Date().toISOString(), sha: process.env.GITHUB_SHA || '', files, hasDom, regions };

fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(
  path.join(outDir, 'src-manifest.json'),
  JSON.stringify(manifest, null, 2)
);

console.log(
  'src-manifest.json written to ' + outDirName + '/ —',
  files.length, 'files,', regions.length, 'regions, hasDom=' + hasDom
);
