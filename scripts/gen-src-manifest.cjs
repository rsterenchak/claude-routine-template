// Build helper — writes the current source inventory to dist/src-manifest.json
// so the in-app Claude assistant's Worker can fetch an always-current file list
// instead of relying on a hand-maintained list baked into the Worker prompt.
//
// ─────────────────────────────────────────────────────────────────
// TEMPLATE INSTANTIATION NOTES
// This file is the ESM-compatible (.cjs) variant. Use it when this project's
// package.json HAS "type": "module".
//
// If package.json does NOT have "type": "module", DELETE THIS FILE and use the
// .js variant instead. The .cjs extension forces Node to treat this file as
// CommonJS even when the surrounding project is ESM — necessary because the
// script uses require() and __dirname, which aren't available in pure ESM.
//
// The script is invoked by deploy.yml after the build step:
//   - name: Generate source manifest
//     run: node scripts/gen-src-manifest.cjs
//     working-directory: <your project's working dir>
//
// Output: dist/src-manifest.json published alongside the built assets so the
// in-app Claude assistant fetches it at:
//   https://<owner>.github.io/<repo>/src-manifest.json
// (or whatever the project's deploy URL pattern is for static assets).
//
// ALSO: many ESM projects (Vite, Next.js, etc.) put their build output in
// `dist/`, but some use `build/`, `.next/`, or other paths. Adjust the
// `distDir` resolution below if your project's build output goes elsewhere.
// ─────────────────────────────────────────────────────────────────

const fs = require('fs');
const path = require('path');

// `__dirname` resolves to scripts/, so srcDir is one level up at src/.
// If your project's source is at a DIFFERENT path relative to this script
// (e.g. lib/, app/src/, packages/web/src/ for monorepos), adjust the
// path.resolve call below.
const srcDir = path.resolve(__dirname, '..', 'src');
const distDir = path.resolve(__dirname, '..', 'dist');

// File extensions to include. Defaults cover most modern web stacks
// (JS/JSX/TS/TSX/CSS). Adjust if your project has other source types worth
// surfacing — e.g. add 'vue', 'svelte', 'astro' for those frameworks; 'md'
// if markdown files are load-bearing source.
const files = fs
  .readdirSync(srcDir)
  .filter((f) => /\.(?:jsx?|tsx?|css)$/.test(f))
  .sort();

fs.mkdirSync(distDir, { recursive: true });

const manifest = {
  generatedAt: new Date().toISOString(),
  sha: process.env.GITHUB_SHA || '',
  files,
};

fs.writeFileSync(
  path.join(distDir, 'src-manifest.json'),
  JSON.stringify(manifest, null, 2)
);

console.log('src-manifest.json written:', files.length, 'files');
