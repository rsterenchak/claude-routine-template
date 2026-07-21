# Claude routine template

A GitHub template repo that scaffolds the file structure for participating in Robert's Claude routine — an automation pipeline where TODO entries get implemented by Claude Code (Opus) in CI, with a conversational planner (Sonnet) in a PWA assisting with authoring.

If you're creating a new repo that should be part of this routine, use the **"Use this template"** button on GitHub. If you're adding the routine to a repo that **already exists**, use `onboard.sh` instead — see [ONBOARD.md](./ONBOARD.md). `onboard.sh` is the smarter path: it detects your shape, writes only the files that shape needs, and never clobbers existing files.

---

## Project shapes

The routine supports several project shapes. What separates them is **whether and how a project publishes its source manifest** (`src-manifest.json`) — the file the dashboard's Structure tab and the in-app Claude assistant fetch to learn a repo's layout and populate the file picker. Every shape except `repo-only` publishes one; they differ in how it's generated and where it's served.

The manifest also drives the Structure tab's **second lens** (the first is always the Code lens — a file tree). A web repo declares `lens:"ui"` (a live map of on-screen regions); a C# repo declares `lens:"types"` (a class/member outline); a SQL repo declares `lens:"sql"` (a table → column outline). The same parameterized generator produces all three, switched by a `MANIFEST_LANG` env var.

### Web shapes

**Build-pipeline** — the project has a build step (webpack, Vite, etc.) that outputs to `dist/`, published to GitHub Pages via a `gh-pages` branch. The manifest is generated into `dist/` at build time (web mode) and published alongside the build output.
- Uses: `deploy.yml`
- Manifest: web mode → `dist/`; Pages serves from the `gh-pages` branch
- Lens: Code + UI
- Examples: a Webpack/Vite SPA

**Served-from-source** — no build step; the source files *are* the served files, served straight from `main` (Pages → "Deploy from a branch → main → root"). No `dist/`.
- Uses: `manifest.yml`
- Manifest: web mode → repo root; Pages serves from `main`, root
- Lens: Code + UI
- Examples: a plain HTML/CSS/JS site

### .NET shapes (console / desktop / maui)

A C# project has a `.csproj`/`.sln` and no `package.json`. It doesn't deploy a site, but it **does** publish a source manifest (csharp mode) — a recursive `.cs` walk that emits a file tree plus a best-effort type outline — served from `main`/root, so the Structure tab gets a Code lens **and** a Types lens. All three .NET shapes share `manifest-dotnet.yml` (written into the target as `manifest.yml`) and the generator; they differ only in their **test** workflow.

**Console** — cross-platform .NET (console app, CLI, class lib). Tests run on ubuntu.
- Test: `test-dotnet.yml` → `test.yml` (ubuntu, `dotnet test`)

**Desktop** — WinForms/WPF (Windows Desktop SDK). Needs the Windows targeting packs, so tests run on windows-latest.
- Test: `test-dotnet-windows.yml` → `test.yml` (windows-latest)

**Maui** — .NET MAUI mobile. Builds the Android head on ubuntu (installs the maui-android workload). Detected *before* desktop, since a MAUI multi-target usually also lists `net*-windows`.
- Test: `test-maui.yml` → `test.yml` (Android build, ubuntu)

All three: manifest via `manifest-dotnet.yml` → `manifest.yml` (csharp mode), served from `main`/root. Lens: Code + Types. Deploy: none.

### SQL shape

**Sql** — a `.sql` schema/migrations repo (no `package.json`, no `.csproj`). Like the .NET shapes it doesn't build, test, or deploy, but it **does** publish a source manifest (sql mode) — a recursive `.sql` walk that extracts each `CREATE TABLE` and its columns/constraints — served from `main`/root, so the Structure tab gets a Code lens **and** a SQL lens (table → column outline, with foreign keys shown inline).
- Uses: `manifest-sql.yml` → `manifest.yml`
- Manifest: sql mode → repo root; Pages serves from `main`, root
- Lens: Code + SQL
- Test / deploy: none
- Examples: a Postgres schema repo, a migrations folder

### repo-only shape

**Repo-only** — a backlog/storage repo with nothing to build, test, deploy, or scan: notes, docs, study material, a bare TODO tracker. The routine (`claude-run.yml` + `TODO.md` + the routine docs) still works, but there's no test/deploy/manifest workflow.
- Uses: universal files only
- Manifest: **none** — the file picker stays in free-text mode for these
- Lens: none

You pick the shape during onboarding. `onboard.sh` detects it — the web shapes from build/bundler signals, the .NET shapes from a `.csproj`/`.sln` (with the TFM deciding console vs desktop vs maui), the sql shape from `.sql` files with no `package.json`, and repo-only as the fallback when nothing buildable/servable/scannable is present — and asks you to confirm, with an override if it guesses wrong. Via the template button, you keep the files for your shape and delete the rest.

> **`repo-only` repos lean on `CLAUDE.md` more than the others.** Because a `repo-only` repo publishes no manifest, neither the chat assistant nor the claude-run agent can fetch a file list to learn the layout — so they're more prone to guessing file paths. Filling in `CLAUDE.md`'s "Key files in this repo" section (Step 2) is therefore *most important* for `repo-only` repos. The manifest-publishing shapes (web, .NET, SQL) have the manifest as a backstop, but a good key-files section still helps everywhere — a wrong file path in a drafted TODO entry is usually an incomplete key-files section.

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
│   ├── routine.md                  # Project-specific commands and conventions (fill in)
│   └── triage.md                   # Triage-sweep instructions (read-only backlog pass)
├── .github/
│   └── workflows/
│       ├── claude-run.yml          # Dispatches Claude Code on TODO.md entries (all shapes)
│       ├── claude-triage.yml       # Read-only triage sweep (all shapes)
│       ├── test.yml                # CI test runner for the WEB shapes (npm)
│       ├── test-dotnet.yml         # CONSOLE shape: dotnet build + test on ubuntu (→ test.yml)
│       ├── test-dotnet-windows.yml # DESKTOP shape: dotnet build + test on windows-latest (→ test.yml)
│       ├── test-maui.yml           # MAUI shape: dotnet MAUI Android build on ubuntu (→ test.yml)
│       ├── deploy.yml              # BUILD-PIPELINE: build + manifest to dist/ + publish to gh-pages
│       ├── manifest.yml            # SERVED-FROM-SOURCE: regenerate + commit web manifest to root
│       ├── manifest-dotnet.yml     # .NET shapes: publish csharp-mode manifest to root (→ manifest.yml)
│       └── manifest-sql.yml        # SQL shape: publish sql-mode manifest to root (→ manifest.yml)
└── scripts/
    ├── gen-src-manifest.js         # The manifest generator, CommonJS  — keep ONE variant
    └── gen-src-manifest.cjs        # The manifest generator, ESM twin  — keep ONE variant
```

Every file has template instantiation notes at the top explaining what to fill in and what to leave alone. Read those before editing.

Which files a shape uses:
- **Web:** the npm `test.yml`, one generator variant, and one of `deploy.yml` / `manifest.yml`.
- **.NET (console/desktop/maui):** `claude-run.yml` + one dotnet test workflow (from `test-dotnet.yml` / `test-dotnet-windows.yml` / `test-maui.yml`) + the generator + `manifest-dotnet.yml` + the routine docs. No web workflows, no `.cjs` (a .NET repo has no `package.json`, so no ESM ambiguity — it keeps the `.js`).
- **SQL:** `claude-run.yml` + the generator + `manifest-sql.yml` + the routine docs. No test workflow (nothing to test in a schema repo), no web workflows, no `.cjs`.
- **repo-only:** the routine docs + `claude-run.yml` + `claude-triage.yml` only.

The two generator files are **identical and parameterized**. They read `MANIFEST_LANG` (`web` default, `csharp`, or `sql`), `MANIFEST_OUT_DIR` (default `dist`; `.` for the root-served shapes), `MANIFEST_SRC_ROOT` (an optional subfolder to scope the .cs/.sql walk), and `MANIFEST_DETERMINISTIC` (`true` for the root-committed shapes, so the manifest only changes when the parsed shape changes). The workflows set these; you don't normally set them by hand. `.js` vs `.cjs` is only about your `package.json`'s module type — the content is the same.

---

## What to do after creating a repo from this template

There are roughly **9–11 steps** depending on your project shape. None are hard; most take less than a minute. The total time is dominated by waiting on deploys and external account configuration, not by active typing.

> **Two settings that can't live in files — do not skip these.** Read-write workflow permissions (Step 9a) and the GitHub Pages source (Step 9b) are GitHub repo *settings*, not files, so they don't come from the template and are easy to miss. If your deploy 403s or your manifest never publishes, it's almost always one of these. (`repo-only` needs read-write permissions only if you wire up claude-run's auto-merge, and never needs Pages. The manifest-publishing shapes — web, .NET, SQL — all need Pages.)

### Step 1 — Pick a manifest generator variant

**`repo-only` repos skip this** — they don't publish a manifest, so delete both `gen-src-manifest.js` and `gen-src-manifest.cjs`.

**.NET and SQL repos keep `gen-src-manifest.js`** and delete the `.cjs` — they have no `package.json`, so there's no ESM ambiguity, and their workflow (`manifest-dotnet.yml` / `manifest-sql.yml`) already references the `.js`.

**Web repos** keep exactly one, by their `package.json`:
- Has `"type": "module"` → keep `.cjs`, delete `.js`
- No `"type": "module"` (or absent) → keep `.js`, delete `.cjs`

Why: Node enforces this at runtime — the wrong extension crashes with `require is not defined` (ESM) or fails to load. The two files have identical content; only the extension differs. **Whichever you keep, make sure the workflow you keep (Step 4) references that same variant** in its `node scripts/gen-src-manifest.*` line, or you'll get `MODULE_NOT_FOUND` at deploy. (`onboard.sh` handles this automatically; the template-button path is manual.)

### Step 2 — Update CLAUDE.md

Follow its onboarding checklist (top of the file): replace every `{{PLACEHOLDER}}`, fill in "Key files in this repo" with the load-bearing files (**most important for `repo-only`** — see the shapes note), then **delete the onboarding checklist section** so future readers see clean docs.

### Step 3 — Update `.claude/routine.md`

Fill in the project-specific commands (test, build, install). The file has comment blocks showing what goes where. Leave `routine-base.md` alone — it's universal.

### Step 4 — Keep and fill the workflow(s) for your shape

- **Build-pipeline:** keep `deploy.yml`; delete `manifest.yml`, `manifest-dotnet.yml`, `manifest-sql.yml`, and the dotnet test workflows. Fill `deploy.yml`'s `{{WORKING_DIR}}`, `{{INSTALL_COMMAND}}`, `{{BUILD_COMMAND}}`, `{{MANIFEST_VARIANT}}`, the `env:` secrets (or delete the block), and the deploy step. Also fill the npm `test.yml`.
- **Served-from-source:** keep `manifest.yml`; delete `deploy.yml`, the dotnet/sql manifest workflows, and the dotnet test workflows. Fill `manifest.yml`'s `{{MANIFEST_VARIANT}}`. Also fill the npm `test.yml`.
- **Console / Desktop / Maui:** delete `deploy.yml`, `manifest.yml`, `manifest-sql.yml`, and the npm `test.yml`. Rename the matching dotnet test workflow (`test-dotnet.yml` / `test-dotnet-windows.yml` / `test-maui.yml`) to `test.yml` and fill its `{{WORKING_DIR}}` (where the `.sln`/`.csproj` lives, `.` if at root) and `{{DOTNET_VERSION}}`. Rename `manifest-dotnet.yml` to `manifest.yml` and fill its `{{MANIFEST_SRC_ROOT}}` (the project's subfolder, blank if at root). The dotnet workflow builds in Release and runs `dotnet test` only when a test project is present, so a no-tests-yet assignment still passes CI.
- **Sql:** delete `deploy.yml`, `manifest.yml`, `manifest-dotnet.yml`, and every test workflow. Rename `manifest-sql.yml` to `manifest.yml` and fill its `{{MANIFEST_SRC_ROOT}}` (blank if your `.sql` sit at the repo root — the common case). There is no test workflow.
- **repo-only:** delete every test/deploy/manifest workflow and both generators. Keep only `claude-run.yml` and `claude-triage.yml`.

For the **web** shapes, also fill `test.yml`'s `{{WORKING_DIR}}`, `{{INSTALL_COMMAND}}`, `{{TEST_COMMAND}}`. No test script yet? Use `npm test --if-present`. If `WORKING_DIR` is `.`, remove the now-redundant `working-directory:` lines.

`claude-run.yml` and `claude-triage.yml` need no changes beyond the secrets in Step 6.

### Step 5 — Configure the Claude GitHub App for this repo

Visit https://github.com/apps/claude and grant it access. It needs to read/write code, open PRs, and post comments.

### Step 6 — Configure secrets in this repo

**Settings → Secrets and variables → Actions**, add:
- **`CLAUDE_CODE_OAUTH_TOKEN`** — your Claude Code Pro/Max OAuth token. Required by `claude-run.yml`. (Don't also add `ANTHROPIC_API_KEY`, or it bills the API instead of your subscription.)
- **`SUPABASE_URL`** + **`SUPABASE_SERVICE_ROLE_KEY`** — required by `claude-triage.yml` (reads flagged rows, writes verdicts back). Same two values across all your repos (one Supabase project). Use the **legacy** service_role JWT — the routine's curls send it on the `Authorization: Bearer` header, which the newer `sb_secret_...` keys reject.
- Any **build-time secrets** your project needs (referenced in `deploy.yml`'s `env:` block).

### Step 7 — Update your GitHub PAT for the worker

Add this repo to the PAT the `todo-injector-worker` uses (https://github.com/settings/personal-access-tokens). Required scopes: `Contents:write` and `Actions:read+write`.

### Step 8 — Register this repo as an inject target

Add an `inject_targets` row so the worker and the PWA can reach this repo. In the PWA, **Inject settings → + Add target**:

- **repo** — `<your-username>/<your-repo>`
- **file** — `TODO.md`
- **src prefix** — the path from repo root to where source lives. For a **web** repo it's usually `src/`; for **.NET** it's the project subfolder (blank if the `.csproj` is at root); for a **SQL** repo whose `.sql` sit at the root it's `""`. It must match the `MANIFEST_SRC_ROOT` you filled in Step 4, since the worker prepends it to the manifest's paths to build raw URLs.

The worker reads `inject_targets` live (via its `resolveTarget`), so there's nothing to deploy — the repo appears in the PWA's workspace pill as soon as the row exists. Onboarding through CI/`onboard.yml` inserts this row automatically.

### Step 9 — Configure the two repo settings the template can't set

**9a — Read-write workflow permissions.** **Settings → Actions → General → Workflow permissions → "Read and write permissions".** New repos default to read-only. Without this, `deploy.yml` 403s pushing `gh-pages`, and the root-committing manifest workflows (`manifest.yml` for served-from-source/.NET/SQL) 403 committing back to `main`.

**9b — GitHub Pages source.** **Settings → Pages → Source: "Deploy from a branch".**
- **Build-pipeline:** branch `gh-pages`, `/ (root)`.
- **Served-from-source, .NET (console/desktop/maui), and SQL:** branch `main`, `/ (root)` — Pages serves the committed `src-manifest.json` directly, no build.
- **repo-only:** skip — no manifest to serve.

If Pages was never enabled, the first run may create/commit the manifest but Pages won't serve until you point it here.

### Step 10 — Verify the manifest publishes

**`repo-only` repos skip this** — there's no manifest; instead confirm `claude-run` dispatches (Step 11). For every other shape, after the first deploy/push confirm the manifest is reachable:

```
https://<your-username>.github.io/<your-repo>/src-manifest.json
```

It should return JSON with a `files` array and the right `lens` for your shape (`"ui"` web, `"types"` .NET, `"sql"` SQL — plus a `types`/`tables` array for the latter two). If it 404s:
- **Build-pipeline:** `deploy.yml` green, right generator variant, build actually output to `dist/` (align generator `MANIFEST_OUT_DIR`, build output dir, and `publish_dir` if your build targets `build/`).
- **Served-from-source / .NET / SQL:** the `manifest.yml` workflow green and committed `src-manifest.json` to root, Pages serving `main`/root (9b), and `src-manifest.json` **not** in `.gitignore` (it must be committed).

### Step 11 — Test injection end-to-end

In the PWA, switch the workspace pill to this repo and inject a trivial entry:

```md
- [ ] **[LOW]** Add a comment to README.md saying "Claude routine integration verified"
  - Type: feature
  - Description: One-line change — add a comment confirming this repo participates in the Claude routine. Smoke test for the integration.
  - File: `README.md`
  - Completed: YYYY-MM-DD (PR #<number>)
```

If `claude-run.yml` dispatches, the PR opens, tests pass, and it auto-merges — you're integrated. Failures usually map to Steps 5, 6, 8, or 9.

### Step 12 — Replace this README

Delete or replace `README.md` with your project's docs. Also delete `ONBOARD.md` and `onboard.sh` if they came along — they're template tooling. (The template button copies the whole repo including these; `onboard.sh` never copies them into target repos.)

---

## After onboarding

- **`CLAUDE.md`** — the agent's primary reference. Keep it current.
- **`TODO.md`** — the backlog. Add entries via the PWA or paste directly.
- **`.claude/routine.md`** — project-specific operational doc. Update when commands change.
- **`.claude/routine-base.md`** — universal; don't edit per-project. Propose changes upstream so all repos benefit.

---

## Troubleshooting common onboarding issues

**Deploy fails with `MODULE_NOT_FOUND` on the manifest step.**
The workflow references a generator variant you deleted (e.g. runs `gen-src-manifest.js` but you kept `.cjs`). Align the workflow's `node scripts/gen-src-manifest.*` line with the variant you kept. (Step 1.)

**Deploy 403s on `git push` to `gh-pages`, or a manifest workflow 403s committing to `main`.**
Workflow permissions are read-only. Set them read-write. (Step 9a.)

**`test.yml` fails with `Missing script: "..."`.**
The test command references a script your `package.json` doesn't have. Set it to your real test script, or `npm test --if-present`. (Step 4.)

**The file picker shows "Enter file path" (free-text) instead of a browsable list.**
The manifest isn't published/reachable. Check the manifest URL returns JSON (Step 10). For the root-served shapes, the usual cause is the manifest never committed to root, or Pages not serving `main`/root. Also hard-refresh the PWA — a failed manifest fetch is cached per session, so a stale 404 persists until reload. (`repo-only` repos are always free-text by design.)

**The manifest URL returns the site's HTML instead of JSON.**
Pages is serving but the manifest isn't at that path — usually a build-output-dir mismatch. Align the three: generator output dir, build output dir, publish dir.

**Files attach but Claude says "file not found."**
The worker's `src_prefix` is wrong. The manifest lists paths relative to `MANIFEST_SRC_ROOT`; the worker prepends `src_prefix` to build the raw URL. Confirm the inject target's `src_prefix` (Inject settings → this repo's row) matches where source actually lives (and the `MANIFEST_SRC_ROOT` you set).

**`claude-run.yml` fails with an authentication error.**
`CLAUDE_CODE_OAUTH_TOKEN` is missing or expired. Re-add it. (Step 6.)

**`claude-triage.yml` fails reading/writing Supabase.**
Missing/invalid `SUPABASE_URL` or `SUPABASE_SERVICE_ROLE_KEY`, or you used a new-style `sb_secret_...` key instead of the legacy service_role JWT. Re-add both, using the legacy key. (Step 6.)

**Injection works but `claude-run.yml` doesn't trigger.**
The worker's PAT lacks access to this repo or lacks `Actions:read+write`. Check its access list and scopes. (Step 7.)

**A root-committing manifest workflow keeps committing on every push / seems to loop.**
The generator isn't in deterministic mode (a volatile timestamp changes every run → always a diff → always a commit), or the loop guards aren't working. Confirm the workflow sets `MANIFEST_DETERMINISTIC: 'true'`, `paths-ignore` includes `src-manifest.json`, and the commit carries `[skip ci]`.

**The chat assistant drafts TODO entries with wrong file paths.**
For a `repo-only` repo there's no manifest, so the assistant guesses paths from names — fill in `CLAUDE.md`'s "Key files in this repo". For a **.NET** repo, the Types manifest is best-effort (regex, not a compiler): heavy generics, indexers/operators, and members after a nested type may be approximate, so an incomplete key-files section still bites. For a **SQL** repo, the sql scanner assumes the common one-definition-per-line `CREATE TABLE` style; an exotic layout may parse loosely. Eyeball drafted file paths before injecting.

**(.NET) `dotnet restore` fails with `MSB1011` ("more than one project or solution file").**
A bare `dotnet restore` is ambiguous with multiple `.csproj`/`.sln`. The template's dotnet workflows discover the `.sln` at runtime and pass it explicitly; if you hand-wrote the workflow, point the commands at the `.sln`.

**(.NET) `dotnet test --no-build` fails with "no test assembly found."**
`--no-build` is fragile when the build graph doesn't match what test expects. The template omits `--no-build` and lets `dotnet test` build what it needs; do the same.

**(.NET) CI fails with "project file was not found" though the `.sln` is present.**
The `.sln` references projects by relative path; if the folders aren't where it points (e.g. files got flattened during a copy), restore fails. Confirm the on-disk layout matches the `.sln`'s references — `git ls-files` shows what's tracked.

**(SQL) The SQL lens is empty or shows "no UI surface" instead of tables.**
Either the manifest hasn't been picked up yet (hard-refresh the PWA — the fetch is cached per session), or the dashboard build in use predates the SQL render branch, which coerces an unknown `lens` value to the UI lens. The Code lens (file tree) working confirms the manifest is wired; the table outline needs a dashboard that handles `lens:"sql"`.

---

## Why this template exists

The Claude routine has 10+ moving parts that must be configured consistently across repos, and several distinct project shapes — web (build-pipeline, served-from-source), .NET (console, desktop, maui), SQL, and repo-only — that need different test/deploy/manifest wiring. Onboarding from scratch each time meant re-deriving what files go where, what commands wire up, and which settings need flipping. This template captures the answers once so subsequent onboardings are mechanical rather than archaeological.

If you hit a project shape this template doesn't cover well, the right move is to onboard once, learn what's missing, and update the template — not to fork it per-project. The served-from-source, console, .NET-desktop/MAUI, and SQL shapes were all added exactly this way: a real (often throwaway) repo of that shape exposed where the assumptions didn't fit, the gaps were fixed in the template, and the next repo of that shape onboarded cleanly. That throwaway-repo-then-fix loop is the intended way to extend this to new shapes (a Python or Java variant would follow the same path).
