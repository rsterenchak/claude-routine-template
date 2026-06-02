# onboard.sh — adding the Claude routine to existing repos

`onboard.sh` scaffolds the Claude routine into an **existing** repository. It's the counterpart to the "Use this template" button: the template button is for new repos created from scratch; this script is for repos that already exist and have their own code, history, and files.

For the conceptual background — the three project shapes (build-pipeline, served-from-source, console), the required repo settings, and full troubleshooting — see [README.md](./README.md). This doc focuses on running the script; it doesn't repeat everything in the README.

## Where this script lives

This script lives in the `claude-routine-template` repo (the same repo whose files it copies). That co-location is deliberate: the script fetches a specific list of files from this template, and those lists (the `COMMON_FILES`, `BUILD_PIPELINE_FILES`, and `SERVED_FROM_SOURCE_FILES` arrays near the top of the script) must stay in sync with the files that actually exist in the template. Keeping the script and the template in one repo means a single commit updates both.

The script does **not** copy itself or this doc into target repos — only the routine files. So onboarding a repo gets it the routine files, not the onboarding tooling.

## How to run it

```bash
# From anywhere, pointing at the repo you want to onboard:
/path/to/onboard.sh ~/code/my-existing-project

# Or clone the template repo and run from there:
git clone https://github.com/rsterenchak/claude-routine-template.git
cd claude-routine-template
./onboard.sh ~/code/my-existing-project

# In a Codespace on the target repo, fetch the script and run against the workspace:
curl -fsSL https://raw.githubusercontent.com/rsterenchak/claude-routine-template/main/onboard.sh -o /tmp/onboard.sh
chmod +x /tmp/onboard.sh
/tmp/onboard.sh /workspaces/<your-repo>
```

The script:
1. Validates the target is a git repo.
2. Detects the project's shape from its `package.json`/file layout (web repos) or `.csproj`/`.sln` (C#/.NET console repos): language, working directory, source directory, test/build commands, **and shape (build-pipeline, served-from-source, or console)**.
3. Shows you a plan: everything it detected, including the deploy shape and *why* it guessed that.
4. **Asks you to confirm the shape** — press Enter to accept, or type `build`/`served`/`console` to override. (Detection is a file-based heuristic; for the web shapes the authoritative signal is the GitHub Pages setting, which isn't in the repo, so you confirm.)
5. Shows which files it will create vs skip, and waits for a final confirmation. **Nothing is written until you say yes.**
6. Fetches the shape-appropriate routine files from the template and writes only the ones that don't already exist.
7. **Prompts for the three human-only values** (project name, description, stack) with detected defaults, then **auto-fills every placeholder** across the created files.
8. Prints the filled values for review plus a checklist of remaining manual steps.

## Deploy shape detection

The script picks between the two shapes (see README for what they mean) from file signals:

- **build-pipeline** — a build script in `package.json` plus a bundler config (`vite.config.*`, `webpack.config.*`, `rollup.config.*`). Scaffolds `deploy.yml`; manifest writes to `dist/`.
- **served-from-source** — no build script, with a root `index.html` and/or a `src/` directory. Scaffolds `manifest.yml`; manifest writes to the repo root and is committed back to `main`.
- **console** — a `.csproj` or `.sln` and no `package.json` (a C#/.NET console app). Scaffolds a `dotnet` test workflow (fetched as `test-dotnet.yml`, written to the target as `test.yml`); no manifest generators, no deploy/manifest workflow. Prompts for the .NET SDK version.

The detection always shows its reasoning and always asks for confirmation, because a confident-but-wrong guess is exactly the failure that's expensive to debug later. If the guess is wrong, type `build` or `served` to override before anything is scaffolded.

## What it will and won't do

**It will:**
- Detect the shape and scaffold only the matching workflow (build-pipeline → `deploy.yml`; served-from-source → `manifest.yml`; console → a dotnet `test.yml`, with no manifest generators or web workflows).
- Detect ESM vs CommonJS and keep the right `gen-src-manifest` variant (`.cjs` for ESM, `.js` for CommonJS).
- Create routine files that don't already exist in the target.
- Prompt for project name / description / stack (with detected defaults) and **auto-fill all `{{PLACEHOLDER}}` values** — working dir, source dir, test/build/install commands, manifest variant, etc. — across CLAUDE.md, routine.md, and the shape's workflow.
- Guess your repo's `owner/name` from its git remote for the worker `ALLOWED_TARGETS` line.

**It won't:**
- Overwrite any existing file. If the target already has a `CLAUDE.md`, a workflow, or `.claude/routine.md`, it's reported as `skip` and left untouched — and its placeholders are NOT filled (the script never edits a file it didn't create). Merge those by hand.
- Touch your source code, `package.json`, or anything outside the routine files.
- Do the external setup or repo-settings changes (GitHub App, secrets, PAT, worker deploy, **read-write workflow permissions, Pages source config**). These involve granting access or flipping settings you should do consciously — the script reminds you in its closing checklist. The two repo settings in particular (workflow permissions and Pages source) are the ones most likely to block you; see README Step 9.
- Fill the freeform sections: CLAUDE.md's "Key files in this repo" and routine.md's conventions/notes sections aren't placeholders, so you write those by hand.

## Requirements

- `bash`, `curl`, and standard unix tools (`grep`, `sed`, `find`). Present on any dev machine and in Codespaces.
- Network access — fetches template files from `raw.githubusercontent.com`.
- The template repo must stay **public** (the script uses unauthenticated raw URLs). If you make it private, switch the fetches to authenticated (`gh api` or `curl` with a token).

## Maintaining the script as the template evolves

When you add, rename, or remove a file in the template, update the relevant array in `onboard.sh` — `COMMON_FILES` for files every shape gets, `BUILD_PIPELINE_FILES` or `SERVED_FROM_SOURCE_FILES` for shape-specific ones. If you forget, onboarding silently skips the new file.

`TEMPLATE_OWNER`, `TEMPLATE_REPO`, and `TEMPLATE_BRANCH` at the top control where it fetches from. Update them if the template moves.

## Detection limits (safe failures)

Detection is best-effort. When it can't determine something it flags "not detected" and fills a readable default rather than guessing silently:

- **Deploy shape** always asks for confirmation, so a wrong guess is caught before scaffolding.
- **Source dir** is checked against `src/`, `app/src/`, `lib/`, `source/`. Unusual layouts (monorepo `packages/*/src/`, `client/src/`) aren't auto-found — review the filled value.
- **Test/build commands** are grepped from `package.json` scripts for common names (`test:run`, `test:ci`, `test`, `build:prod`, `build`). Unusual names fall back to a readable default (`npm test`, `npm run build`).
- **Working dir** is found by locating `package.json` at root or one level down.

Because the script now *fills* values rather than only suggesting them, **review the "Values that were filled in" summary it prints at the end** — a plausible-but-wrong filled value (e.g. a guessed `src/`) is less visible than an obvious unfilled placeholder, so the end-of-run summary exists for you to catch those.

## First real run

The detection, skip-existing, and substitution logic are well-tested; the network fetch should be confirmed once against a throwaway target. Copy a repo to a temp location, run against the copy, and confirm the files land. If you see `FAILED (could not fetch from template)`, either the template constants are wrong or a file in the arrays doesn't exist in the template.

## After running

Follow the printed checklist. The script gets you the files, the shape-appropriate workflow, and the filled placeholders; the remaining work is:
1. Complete the freeform sections (CLAUDE.md "Key files", routine.md conventions).
2. Configure the GitHub App, secrets, and PAT (README Steps 5-7).
3. Flip the two repo settings: read-write workflow permissions, and Pages source for your shape (README Step 9).
4. Add the repo to the worker's `ALLOWED_TARGETS` and deploy the worker (README Step 8).
5. Verify the manifest publishes and inject a test entry (README Steps 10-11).

The README's "What to do after creating a repo from this template" section is the full checklist — the steps are identical whether you came via the template button or this script. The one difference: this script auto-fills the placeholders and picks the workflow for your shape, so you skip the manual variant-selection and placeholder-filling steps.
