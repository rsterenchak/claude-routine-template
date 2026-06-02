# Claude routine template

A GitHub template repo that scaffolds the file structure for participating in Robert's Claude routine — an automation pipeline where TODO entries get implemented by Claude Code (Opus) in CI, with a conversational planner (Sonnet) in a PWA assisting with authoring.

If you're creating a new repo that should be part of this routine, use the **"Use this template"** button on GitHub. If you're adding the routine to a repo that **already exists**, use `onboard.sh` instead — see [ONBOARD.md](./ONBOARD.md).

---

## Two project shapes

The routine supports two kinds of project, and they differ in how the source manifest gets published. The manifest (`src-manifest.json`) is the file the in-app Claude assistant fetches to populate its file picker, so getting it published correctly is what makes a repo's files attachable in chat.

**Build-pipeline** — the project has a build step (webpack, Vite, etc.) that outputs to `dist/`, and that build output is published to GitHub Pages via a `gh-pages` branch. The manifest is generated into `dist/` at build time and published alongside the build output.
- Uses: `deploy.yml`
- Manifest writes to: `dist/`
- Pages serves from: the `gh-pages` branch
- Examples: a Webpack/Vite SPA

**Served-from-source** — the project has no build step; the source files *are* the served files, served straight from `main` (Pages set to "Deploy from a branch → main → root"). There is no `dist/`.
- Uses: `manifest.yml`
- Manifest writes to: the repo root (where Pages serves it)
- Pages serves from: `main`, root
- Examples: a plain HTML/CSS/JS site

You pick the shape during onboarding (the `onboard.sh` script detects it and asks you to confirm; if you came via the template button, you choose which workflow to keep — see Step 4). **Keep only the workflow for your shape** — a build-pipeline repo keeps `deploy.yml` and deletes `manifest.yml`; a served-from-source repo does the reverse.

---

## What's in this template

```
.
├── CLAUDE.md                       # Architecture reference + onboarding checklist
├── TODO.md                         # The backlog file the routine reads
├── README.md                       # This file (delete or replace after onboarding)
├── ONBOARD.md                      # Guide for onboarding EXISTING repos via onboard.sh
├── onboard.sh                      # Script that scaffolds the routine into existing repos
├── .claude/
│   ├── routine-base.md             # Universal routine discipline (identical across projects)
│   └── routine.md                  # Project-specific commands and conventions (fill in)
├── .github/
│   └── workflows/
│       ├── claude-run.yml          # Dispatches Claude Code on TODO.md entries
│       ├── test.yml                # CI test runner
│       ├── deploy.yml              # BUILD-PIPELINE shape: build + manifest to dist/ + publish to gh-pages
│       └── manifest.yml            # SERVED-FROM-SOURCE shape: regenerate + commit manifest to root
└── scripts/
    ├── gen-src-manifest.js         # For CommonJS projects — keep ONE of these
    └── gen-src-manifest.cjs        # For ESM projects ("type": "module") — keep ONE of these
```

Every file has template instantiation notes at the top explaining what to fill in and what to leave alone. Read those before editing.

The two manifest generators are now **identical and parameterized** — they read `MANIFEST_OUT_DIR` (default `dist`, set `.` for served-from-source) and `MANIFEST_DETERMINISTIC` (set `true` for served-from-source so the committed manifest only changes when the file list changes). The workflows set these env vars; you don't normally set them by hand.

---

## What to do after creating a repo from this template

There are roughly **9-11 steps** depending on your project shape. None are hard; most take less than a minute. The total time is dominated by waiting on deploys and external account configurations, not by your active typing time.

> **Two settings that can't live in files — do not skip these.** Two required pieces of setup are GitHub repo settings, not files, so they don't come from the template and are easy to miss. Both bit the first real onboarding hard. They are: **read-write workflow permissions** (Step 9a) and **GitHub Pages source configuration** (Step 9b). If your deploy 403s or your manifest never publishes, it's almost always one of these.

### Step 1 — Pick a manifest generator variant

In `scripts/`, you have both `gen-src-manifest.js` and `gen-src-manifest.cjs`. **Keep one, delete the other.** The decision rule:

- Open `package.json`. Does it have `"type": "module"`?
  - **Yes** → keep the `.cjs` variant, delete the `.js`
  - **No** (or the field is absent) → keep the `.js` variant, delete the `.cjs`

Why: Node.js enforces this at runtime. If you use the wrong extension, the script crashes with `require is not defined` (in ESM projects) or fails to load. The two files have identical content; only the extension differs.

**Whichever variant you keep, make sure the workflow you keep (Step 4) references that same variant** in its `node scripts/gen-src-manifest.*` line. A mismatch here causes `MODULE_NOT_FOUND` at deploy time — the workflow tries to run a file you deleted. (The `onboard.sh` path handles this automatically; the template-button path is manual, so double-check it.)

### Step 2 — Update CLAUDE.md

Open `CLAUDE.md` and follow its onboarding checklist (at the top of the file):

- Replace every `{{PLACEHOLDER}}` with the actual value for your project
- Fill in the "Key files in this repo" section with the load-bearing files
- After everything is filled in, **delete the onboarding checklist section** so future readers see clean documentation

### Step 3 — Update `.claude/routine.md`

Fill in the project-specific commands (test, build, install). The file has comment blocks showing what goes in each section. Leave `routine-base.md` alone — it's universal.

### Step 4 — Keep and fill the workflow for your shape

Decide your shape (see "Two project shapes" above), then:

- **Build-pipeline:** keep `.github/workflows/deploy.yml`, delete `.github/workflows/manifest.yml`. Fill in `deploy.yml`'s placeholders: `{{WORKING_DIR}}`, `{{INSTALL_COMMAND}}`, `{{BUILD_COMMAND}}`, `{{MANIFEST_VARIANT}}` (the generator variant you kept), the build-time secrets in the `env:` block (or delete the block), and the deploy step (keep Pages, or swap for Cloudflare/Vercel/Netlify).
- **Served-from-source:** keep `.github/workflows/manifest.yml`, delete `.github/workflows/deploy.yml`. Fill in `manifest.yml`'s `{{MANIFEST_VARIANT}}`. This workflow regenerates the manifest to the repo root and commits it back to `main` only when the file list changes.

In **both** shapes, also fill `test.yml`'s placeholders: `{{WORKING_DIR}}`, `{{INSTALL_COMMAND}}`, `{{TEST_COMMAND}}`. If your project has no test script yet, set the test command to `npm test --if-present` so CI passes until you add tests. If `WORKING_DIR` is `.`, remove the now-redundant `working-directory:` lines.

`claude-run.yml` needs no changes beyond the secret in Step 6.

### Step 5 — Configure the Claude GitHub App for this repo

Visit https://github.com/apps/claude and grant the app access to your new repo. It needs to read/write code, open PRs, and post comments.

### Step 6 — Configure secrets in this repo

**Settings → Secrets and variables → Actions**, add:

- **`CLAUDE_CODE_OAUTH_TOKEN`** — your Claude Code Pro/Max OAuth token. Required by `claude-run.yml`. (Do not also add `ANTHROPIC_API_KEY`, or it will bill the API instead of your subscription.)
- Any **build-time secrets** your project needs (referenced in `deploy.yml`'s `env:` block).

### Step 7 — Update your GitHub PAT for the worker

Add this repo to the PAT the `todo-injector-worker` uses:
- https://github.com/settings/personal-access-tokens (or classic tokens)
- Add this repo to the PAT's repository access list
- Required scopes: `Contents:write` and `Actions:read+write`

### Step 8 — Add this repo to the worker's `ALLOWED_TARGETS`

In `todo-injector-worker/src/index.js`:

```js
{ repo: "<your-username>/<your-repo>", filePath: "TODO.md", srcPrefix: "<src dir>/" }
```

`srcPrefix` is the path from your repo root to where source files live (`src/`, `app/src/`, etc.). Then deploy: `cd todo-injector-worker && npm run deploy`. The workspace pill in the PWA sources its repo list from the worker, so the repo appears in chat once this deploys.

### Step 9 — Configure the two repo settings the template can't set

**9a — Enable read-write workflow permissions.**
**Settings → Actions → General → Workflow permissions → "Read and write permissions".** New repos default to read-only. Without this:
- A build-pipeline `deploy.yml` 403s when it tries to push the `gh-pages` branch.
- A served-from-source `manifest.yml` 403s when it tries to commit the manifest back to `main`.

**9b — Configure the GitHub Pages source for your shape.**
**Settings → Pages → Source: "Deploy from a branch".**
- **Build-pipeline:** branch `gh-pages`, folder `/ (root)`. Pages serves the published build output.
- **Served-from-source:** branch `main`, folder `/ (root)`. Pages serves your source files directly.

If Pages was never enabled, the first deploy may create the branch but Pages won't serve until you point it here.

### Step 10 — Verify the manifest publishes

After your first deploy/push, confirm the manifest is reachable:

```
https://<your-username>.github.io/<your-repo>/src-manifest.json
```

It should return JSON with a `files` array. If it 404s:
- **Build-pipeline:** check `deploy.yml` ran green, the manifest step used the right generator variant, and the build actually output to `dist/` (some projects build to `build/` — if so, align the generator's `MANIFEST_OUT_DIR`, the build output dir, and `deploy.yml`'s `publish_dir`).
- **Served-from-source:** check `manifest.yml` ran green and committed `src-manifest.json` to the repo root, and that Pages serves from `main`/root (Step 9b). Confirm `src-manifest.json` is NOT in `.gitignore` (it must be committed).

### Step 11 — Test injection end-to-end

In the PWA, switch the workspace pill to this repo and inject a trivial test entry:

```md
- [ ] **[LOW]** Add a comment to README.md saying "Claude routine integration verified"
  - Type: feature
  - Description: One-line change — add a comment confirming this repo participates in the Claude routine. Smoke test for the integration.
  - File: `README.md`
  - Completed: YYYY-MM-DD (PR #<number>)
```

If `claude-run.yml` dispatches, the PR opens, tests pass, and it auto-merges — you're integrated. Failures usually map to Steps 5, 6, 8, or 9.

### Step 12 — Replace this README

Delete or replace `README.md` with your actual project's documentation. Also delete `ONBOARD.md` and `onboard.sh` if they came along — they're template tooling, not part of your project. (The "Use this template" button copies the whole template repo, including these; `onboard.sh` itself does not copy them into target repos.)

---

## After onboarding

- **`CLAUDE.md`** — the agent's primary reference. Keep it current.
- **`TODO.md`** — the backlog. Add entries via the PWA or paste directly.
- **`.claude/routine.md`** — project-specific operational doc. Update when commands change.
- **`.claude/routine-base.md`** — universal; don't edit per-project. Propose changes upstream so all repos benefit.

---

## Troubleshooting common onboarding issues

**Deploy fails with `MODULE_NOT_FOUND` on the manifest step.**
The workflow references a generator variant you deleted (e.g. it runs `gen-src-manifest.js` but you kept `.cjs` for an ESM project). Align the workflow's `node scripts/gen-src-manifest.*` line with the variant you kept. (Step 1.)

**Deploy fails with a 403 on `git push` to `gh-pages`, or `manifest.yml` 403s committing to `main`.**
Workflow permissions are read-only. Set them to read-write. (Step 9a.)

**`test.yml` fails with `Missing script: "..."`.**
The test command references a script your `package.json` doesn't have. Set it to your actual test script, or `npm test --if-present` if you have no tests yet. (Step 4.)

**The file picker shows "Enter file path" (free-text) instead of a browsable list.**
The manifest isn't published/reachable for this repo. Check the manifest URL returns JSON (Step 10). For served-from-source, the most common cause is the manifest never being committed to root, or Pages not serving from `main`/root. Also try a hard-refresh of the PWA — a failed manifest fetch is cached per session, so a stale 404 from before the manifest existed will persist until you reload.

**The manifest URL returns the site's HTML instead of JSON.**
Pages is serving, but the manifest isn't at that path — usually a build-output-dir mismatch (the build outputs somewhere other than where the manifest was written / where `publish_dir` points). Align the three: generator output dir, build output dir, publish dir.

**Files attach but Claude says "file not found."**
The worker's `srcPrefix` is wrong. The manifest lists bare filenames (`main.js`); the worker prepends `srcPrefix` (`src/`) to build the raw URL. Confirm the `ALLOWED_TARGETS` entry's `srcPrefix` matches where source actually lives.

**`claude-run.yml` fails with an authentication error.**
`CLAUDE_CODE_OAUTH_TOKEN` is missing or expired. Re-add it. (Step 6.)

**Injection works but `claude-run.yml` doesn't trigger.**
The worker's PAT lacks access to this repo or lacks `Actions:read+write`. Check its repository access list and scopes. (Step 7.)

**The served-from-source `manifest.yml` keeps committing on every push / seems to loop.**
The generator isn't running in deterministic mode (volatile timestamp changes every run → always a diff → always a commit), or the loop guards aren't working. Confirm `manifest.yml` sets `MANIFEST_DETERMINISTIC: 'true'`, that `paths-ignore` includes `src-manifest.json`, and that the commit message carries `[skip ci]`. With those, an unchanged file list produces no commit and the manifest commit doesn't re-trigger the workflow.

---

## Why this template exists

The Claude routine has 10+ moving parts that have to be configured consistently across repos, and there are at least two distinct project shapes (build-pipeline and served-from-source) that need different deploy wiring. Onboarding from scratch each time meant re-deriving "what files go where," "what commands wire up," and "which settings need flipping." This template captures the answers once so subsequent onboardings are mechanical rather than archaeological.

If you hit a project shape this template doesn't cover well, the right move is to onboard once, learn what's missing, and update the template — not to fork the template per-project. The served-from-source shape itself was added exactly this way, after a real repo exposed that the build-pipeline assumptions didn't fit.
