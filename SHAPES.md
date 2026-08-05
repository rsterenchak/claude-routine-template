# Shape templates

One GitHub template repository per shape `onboard.sh` resolves. Each is a
**pre-onboard** project: real starter code, laid out so shape detection resolves
correctly and preflight returns zero warnings — and nothing else. No `CLAUDE.md`,
no `TODO.md`, no workflows. Those are what onboarding adds, and leaving them out
is what makes a fresh repo's preflight show a full `create[]` list.

## Verified

Every template below was run through the patched `onboard.sh` in preflight mode.
Shape, derived commands, and warning count are actual output, not intent.

| Template | Shape | Test command | Warnings |
|---|---|---|---|
| `template-served-from-source` | served-from-source | `npm run test:run` | 0 |
| `template-console` | console | `dotnet test` | 0 |
| `template-desktop` | desktop | `dotnet test` | 0 |
| `template-sql` | sql | none | 0 |
| `template-repo-only` | repo-only | none | 0 |

## Setup

For each folder: create a repo, push it, then **Settings → check "Template
repository"**. After that, "Use this template" creates a new repo you can
preflight and onboard.

```bash
cd template-console
git remote add origin https://github.com/rsterenchak/template-console
git push -u origin main
gh repo edit rsterenchak/template-console --template
```

Keep them public or private to taste — onboarding works either way, but a
private template still needs the Worker PAT to reach it.

## The two shapes with no template here

**build-pipeline (Angular).** A hand-written Angular app goes stale the moment
the CLI ships a new version, and the one setting that matters — `--base-href
/<repo>/` — is repo-name-specific and cannot be baked into a template. `ng new`
generates ~30 files (`angular.json`, three tsconfigs, the `src/app/` tree, a
pinned dependency graph); there is no useful way to start from another template
and edit toward it. Use the CLI.

### From a Codespace

Create the repo on GitHub first — empty, with a README so `main` exists — then
open a Codespace on it and generate in place:

```bash
ng new my-app --routing --style=css --directory . --skip-git
```

`--directory .` matters: without it `ng new` makes a subfolder, `angular.json`
lands one level deep, and every workflow ends up carrying
`working-directory: my-app`. It still works, it is just noisier. `--skip-git`
matters because the Codespace is already a git repo and `ng new` would try to
init another one.

If `ng` is not on the Codespace image: `npm install -g @angular/cli`.

Then apply the three edits below, commit, push, and Check from the PWA.

### From a laptop

```bash
ng new my-app --routing --style=css
cd my-app
gh repo create rsterenchak/my-app --private --source=. --push
```

### The three edits, either way

```jsonc
// angular.json — flatten dist/<project>/browser to dist/, which is where
// deploy.yml's publish_dir and the manifest step both point.
"outputPath": { "base": "dist", "browser": "" }

// package.json
"build": "ng build --base-href /<repo-name>/",
"test:run": "ng test --no-watch --browsers=ChromeHeadless"
```

Plus a `404.html` copy of `index.html` if the app uses the router — GitHub Pages
has no SPA rewrite, so deep links 404 on refresh.

Preflight AFTER those edits, not before. Detection resolves `build-pipeline`
either way (`angular.json` is a recognized bundler config), but the derived
`test_command` comes straight from `package.json` — so a preflight run before
the `test:run` edit bakes `npm test` into the report, and onboarding at that
point would write Angular's default `ng test` into `test.yml`, which launches a
real Chrome in watch mode and hangs CI. Existing files are never overwritten, so
fixing it afterward means hand-editing `test.yml` or deleting and re-onboarding.

Note also that preflight cannot verify the `outputPath` edit — today's Angular
warning fires on `angular.json` merely existing, not on anything being wrong.
Check that one by reading the file.

**maui.** `dotnet new maui` generates a multi-target `.csproj`, `Platforms/`
folders, XAML pages, and resource directories — the same situation as Angular,
where editing another template toward it means rebuilding a scaffold by hand.

```bash
dotnet workload install maui

dotnet new maui -n MyApp -o src/MyApp
dotnet new sln -n MyApp
dotnet sln add src/MyApp/MyApp.csproj

# Optional but recommended — without a test project there is no CI gate,
# and PRs auto-merge with nothing checking them.
dotnet new xunit -o tests/MyApp.Tests
dotnet add tests/MyApp.Tests reference src/MyApp
dotnet sln add tests/MyApp.Tests/MyApp.Tests.csproj
```

`dotnet new xunit` brings in `Microsoft.NET.Test.Sdk`, which is the marker
`test.yml` greps for to tell a test project from a runnable one.

Keep testable logic out of the XAML code-behind, for the same reason the desktop
template keeps it out of the `Form`: CI cannot instantiate a page.

Detection routes this on the `-android` / `-ios` / `-maccatalyst` target
frameworks, checked **before** the desktop signal. That order matters — a MAUI
multi-target usually also lists `net8.0-windows`, which would otherwise send the
repo to the windows-latest workflow that cannot build MAUI at all.

Two things to expect:

- **Android head only.** The workflow installs the `maui-android` workload on
  ubuntu; iOS and Mac Catalyst targets cannot build there.
- **No Capture card.** Deliberate — there is no runnable head to `dotnet run`.

**This is the least-proven shape in the pipeline.** `test-maui.yml` has never
executed against a real project. Onboard a throwaway first and let CI actually
run before a graded repo depends on it — that run also tells you whether the
workload-install-plus-build time is tolerable given one entry at a time.

## What each template is shaped around

- **served-from-source** — `package.json` with a `test:run` and **no build
  script**, plus a root `index.html`. The absent build script is what separates
  this shape from build-pipeline. `"type": "module"` selects the `.cjs` manifest
  generator.
- **console** — exactly one `OutputType=Exe` project. `run-capture.yml`
  auto-discovers the single non-test runnable project; a second one makes it
  ambiguous and the Capture card returns nothing.
- **desktop** — `<UseWindowsForms>true</UseWindowsForms>` routes to
  windows-latest. Logic lives outside the `Form` so CI can test it headlessly.
- **sql** — `.sql` files and no `package.json`. Conventional `CREATE TABLE`
  statements so the Structure tab's SQL lens can parse a column outline.
- **repo-only** — no `src/` directory, deliberately. A `src/` folder is read as a
  web-source signal and would route the repo to served-from-source, which then
  gets a Node `test.yml` it cannot satisfy.

## Lockfiles

`template-served-from-source` ships a `package-lock.json`. Keep it. `test.yml`
uses `cache: npm` with `cache-dependency-path`, and a missing lockfile fails
`setup-node` before a single test runs.
