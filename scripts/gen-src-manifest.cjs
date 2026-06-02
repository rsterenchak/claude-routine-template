// Build helper — writes the current source inventory to src-manifest.json so
// the in-app Claude assistant's Worker can fetch an always-current file list.
//
// ─────────────────────────────────────────────────────────────────
// TEMPLATE INSTANTIATION NOTES
// This is the CommonJS (.js) variant. Use it when package.json does NOT have
// "type": "module". For ESM projects ("type": "module"), use the .cjs variant.
//
// Parameterized by two environment variables so one script serves both project
// shapes:
//
//   MANIFEST_OUT_DIR   — where to write src-manifest.json, relative to the repo
//                        root. Default "dist" (build-pipeline projects whose
//                        build output is published). Set "." for served-from-
//                        source projects (served straight from the repo root on
//                        main — no build, no dist/).
//
//   MANIFEST_DETERMINISTIC — "true" omits the volatile generatedAt/sha fields so
//                        the manifest only changes when the file LIST changes.
//                        Used by served-from-source projects whose workflow
//                        commits the manifest back to the branch (volatile
//                        fields would force a commit on every push). Build-
//                        pipeline projects leave this unset.
//
// The onboard script sets these based on detected project shape. If you run the
// generator by hand, set them to match your shape (or accept the dist/ default).
// ─────────────────────────────────────────────────────────────────

const fs = require('fs');
const path = require('path');

const srcDir = path.resolve(__dirname, '..', 'src');

const outDirName = process.env.MANIFEST_OUT_DIR || 'dist';
const outDir = path.resolve(__dirname, '..', outDirName);

const files = fs
  .readdirSync(srcDir)
  .filter((f) => /\.(?:jsx?|tsx?|css|html)$/.test(f))
  .sort();

const deterministic = process.env.MANIFEST_DETERMINISTIC === 'true';
const manifest = deterministic
  ? { files }
  : { generatedAt: new Date().toISOString(), sha: process.env.GITHUB_SHA || '', files };

fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(
  path.join(outDir, 'src-manifest.json'),
  JSON.stringify(manifest, null, 2)
);

console.log('src-manifest.json written to ' + outDirName + '/ —', files.length, 'files');
