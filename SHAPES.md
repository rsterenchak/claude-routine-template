# Project shapes

How to start a repo for each shape `onboard.sh` resolves, so that preflight comes
back clean and onboarding writes the right workflows.

<!--
  PARSING CONTRACT — the PWA's Repo setup picker reads this file live from
  raw.githubusercontent.com and parses four markers. Reword them and the picker
  degrades SILENTLY: rows render with missing chips and no gotchas, and nothing
  errors. Adding a shape, by contrast, needs no client change at all.

    ## <shape-name>          → one picker row (heading text is the row label)
    **Template:** `owner/x`  → TEMPLATE chip + the copyable value
    **Onboarding adds:**     → the chip list, up to the end of that paragraph
    **Gotchas**              → the amber list; every `- ` bullet until the next
                               heading or `---`

  A section with no `**Template:**` line is labelled CLI, and its copyable value
  is the first fenced code block.

    ### <variant-name>       → OPTIONAL. When a section contains `### ` blocks,
                               render them as a segmented control inside the
                               expanded row, each with its own fenced blocks.
                               Sections with none render exactly as before.

  Inside a variant, the FIRST fenced block is the scaffold command and every
  block after it is an edit block. Each gets its own copy control.

    **File:** `path`         → line immediately before a fence, rendered as that
                               block's label. Keeps the path OUT of the copied
                               text.

  Fenced blocks contain ONLY what should be pasted. No `#` or `//` comment naming
  the file, no explanation — both copy with the code. Reasoning goes in Gotchas. A section containing `least-proven` gets the
  warning glyph; one containing `**No shape exists.**` is dimmed and labelled
  NO SHAPE.

  Prose outside these markers is free-form — only the four markers are load-
  bearing, plus the `## ` heading level.
-->

Every `##` section below is one shape.

Templates are **pre-onboard**: real starter code and nothing else. No `CLAUDE.md`,
no `TODO.md`, no workflows — those are what onboarding adds, and leaving them out
is what makes a fresh repo's preflight show a full `create[]` list.

Two courses have no shape because the pipeline does not apply. **Version Control
(D197)** is GitLab-based with screenshot deliverables. **UI Design / UX Design**
onboard as `repo-only` and work fine, but the deliverables are wireframes and
Figma files — the pipeline's value is code PRs, so expect little from it there.

---

## build-pipeline

Bundled web app published to `gh-pages`. Angular, React, Vue, the PWA itself.

**No template** — framework scaffolds are versioned and go stale, and the one
setting that matters (`--base-href` / `--base`) is repo-name-specific and can't
be baked in. Use the framework's own CLI.

Create the repo on GitHub first (empty, with a README so `main` exists), open a
Codespace on it, then scaffold in place. Generating into the current directory
avoids a subfolder that would push the config a level deep and leave every
workflow carrying `working-directory: my-app`.

**Onboarding adds:** `deploy.yml`, `test.yml`, a manifest generator.
Pages source: `gh-pages`, root.

### angular

**File:** `angular.json` → `projects.<name>.architect.build.options`

```jsonc
"outputPath": { "base": "dist", "browser": "" }
```

**File:** `package.json` → `scripts`

```jsonc
"build": "ng build --base-href /my-app/",
"test:run": "ng test --no-watch"
```

**Scaffold** (empty repo)

```bash
ng new my-app --routing --style=css --directory . --skip-git
```

Run `npm install -g @angular/cli` first if `ng` is missing. Answer **No** to SSR
and **None** to the AI-tools prompt.

### react

**File:** `package.json` → `scripts`

```jsonc
"build": "vite build --base=/my-app/",
"test:run": "vitest run"
```

**Scaffold** (empty repo)

```bash
npm create vite@latest . -- --template react
npm install
npm install -D vitest
```

Vite already outputs to `dist/`, so there is no `outputPath` edit.
`matchingGame-test` is a working reference.

### vue

**File:** `package.json` → `scripts`

```jsonc
"build": "vite build --base=/my-app/",
"test:run": "vitest run"
```

**Scaffold** (empty repo)

```bash
npm create vue@latest .
npm install
```

Interactive — choose **Vitest** when asked, or there is no test gate. Vue writes
its own `test:unit`; add `test:run` alongside it, since detection looks for
`test:run` then `test:ci` then `test`.

**Gotchas**
- **Apply the edits before preflighting.** `test_command` is read straight from
  `package.json`, so preflighting first bakes the wrong command into the report,
  and onboarding writes it into `test.yml`. Files are never overwritten, so fixing
  it means hand-editing `test.yml` or deleting and re-onboarding.
- **Put each edit in the file its label names.** A `scripts` entry pasted into
  `angular.json` overwrites the `test` target, and every `ng` command then fails
  with `Skipping invalid target value; expected an object`.
- **Angular 21 uses Vitest, not Karma.** `--browsers=ChromeHeadless` is a Karma
  flag and `@angular/build:unit-test` rejects it. `--no-watch` is the single-run
  flag. Verified on CLI 21.2.20 / Vitest 4.1.10.
- **Preflight cannot verify these edits.** Its Angular warning fires on
  `angular.json` merely existing, so it reads identically on a correct repo and a
  broken one. Only a deploy that renders proves `outputPath`.
- `--base-href` / `--base` must match the repo name. Project Pages serve from
  `/<repo>/` and every framework hardcodes `/`, so assets 404 without it.
- Add a `404.html` copy of `index.html` if the app routes — Pages has no SPA
  rewrite, so deep links 404 on refresh.
- Commit the lockfile. `test.yml` uses `cache: npm` with
  `cache-dependency-path`; without it `setup-node` fails before any test runs.

---

## served-from-source

Static site with no build step. The files in the repo are the files the browser
gets. Plain HTML/CSS/JS coursework.

**Template:** `rsterenchak/template-served-from-source`

**Onboarding adds:** `manifest.yml` (regenerates the source manifest and commits
it to the repo root), `test.yml`. Pages source: `main`, root.

**Gotchas**
- The absence of a `build` script is what separates this from build-pipeline.
  Add one and the repo becomes build-pipeline.
- `"type": "module"` selects the `.cjs` manifest generator over the `.js` one.
- Deleting `package.json` still resolves to served-from-source, but you lose the
  test gate and PRs auto-merge with nothing checking them.
- Ships with a `package-lock.json`. Keep it.

---

## console

Cross-platform .NET console app. Software I, DSA practice, anything with a
runnable `Main`.

**Template:** `rsterenchak/template-console`

**Onboarding adds:** `test.yml` (dotnet test on ubuntu), `manifest.yml`,
`run-capture.yml`. Pages source: `main`, root (manifest only — no app deploy).

**Gotchas**
- **Exactly one `OutputType=Exe` project.** `run-capture.yml` auto-discovers the
  single non-test runnable project; a second makes it ambiguous and the Capture
  card returns nothing. New executables belong in new repos.
- `.csproj`/`.sln` must be within two directories of the root or the repo isn't
  detected as .NET at all and silently becomes `repo-only`.
- Keep the `.sln` at the root so `WORKING_DIR` stays `.`.
- `Microsoft.NET.Test.Sdk` is the marker that tells a test project from a
  runnable one.

---

## desktop

WinForms or WPF. Software II.

**Template:** `rsterenchak/template-desktop`

**Onboarding adds:** `test.yml` running on **windows-latest**, `manifest.yml`.
No `run-capture.yml` — `dotnet run` on a GUI app opens a window and hangs a
headless runner.

**Gotchas**
- `<UseWindowsForms>true</UseWindowsForms>` (or `<UseWPF>`, or a `net*-windows`
  TFM) is the routing signal. Without it the repo resolves to `console` and
  `dotnet build` fails on ubuntu — the Windows Desktop targeting packs ship with
  the SDK only on Windows.
- Keep testable logic out of the `Form`. CI can't instantiate one.
- windows-latest is slower and costs more Actions minutes than console.

---

## maui

.NET mobile. Mobile Application Development.

**No template** — `dotnet new maui` generates a multi-target `.csproj`,
`Platforms/` folders, XAML pages, and resource directories.

The xUnit project is optional but recommended — without one there is no CI gate
and PRs auto-merge with nothing checking them.

```bash
dotnet workload install maui

dotnet new maui -n MyApp -o src/MyApp
dotnet new sln -n MyApp
dotnet sln add src/MyApp/MyApp.csproj

dotnet new xunit -o tests/MyApp.Tests
dotnet add tests/MyApp.Tests reference src/MyApp
dotnet sln add tests/MyApp.Tests/MyApp.Tests.csproj
```

**Onboarding adds:** `test.yml` (MAUI Android build on ubuntu), `manifest.yml`.
No Capture card — there's no runnable head.

**Gotchas**
- Detection routes on the `-android` / `-ios` / `-maccatalyst` TFMs, checked
  **before** the desktop signal. That order is load-bearing: a MAUI multi-target
  usually also lists `net*-windows`, which would otherwise send it to the
  windows-latest workflow that can't build MAUI at all.
- **Android head only.** iOS and Mac Catalyst can't build on ubuntu.
- Keep logic out of the XAML code-behind, same reason as desktop.
- **Least-proven shape in the pipeline.** `test-maui.yml` has never executed
  against a real project. Onboard a throwaway and let CI run before a graded
  repo depends on it — that also tells you whether workload-install-plus-build
  time is tolerable given one entry at a time.

---

## sql

Schema and migrations, no application code. Advanced Data Management.

**Template:** `rsterenchak/template-sql`

**Onboarding adds:** `manifest.yml` running the generator in SQL mode, which
publishes a table outline the Structure tab reads. No test workflow — nothing to
run. Pages source: `main`, root.

**Gotchas**
- `.sql` files must be within four directories of the root.
- Keep `CREATE TABLE` statements conventional so the SQL lens can parse them into
  a column outline. Exotic DDL still runs, it just won't appear in the lens.
- `.sql` at the repo root is the easy case — `srcPrefix` ends up blank and
  matches the registry row. In a subfolder, both must be set to the same value.

---

## repo-only

Storage repo: notes, research, planning, write-ups. UI Design, UX Design,
Software Design & QA.

**Template:** `rsterenchak/template-repo-only`

**Onboarding adds:** the routine, triage, and `TODO.md`. No test, deploy, or
manifest.

**Gotchas**
- **Don't add a `src/` folder.** It's read as a web-source signal and routes the
  repo to served-from-source, which then gets a Node `test.yml` it can't satisfy.
  Use `notes/` or anything else.
- No CI gate, so PRs auto-merge with no status check. Fine unless the repo has
  branch protection requiring one.

---

## python

**No shape exists.** A Python repo with `src/` trips the served-from-source rule
and gets a Node `test.yml` it can't run.

Until a shape is added, override to `repo-only` at the shape prompt and accept no
CI gate — which is a real cost on algorithm code, where a test gate is worth the
most.

Adding it would mean: `pip install -r requirements.txt` / `pytest`, no build, no
Pages, and a `.py` extension in the manifest generator.
