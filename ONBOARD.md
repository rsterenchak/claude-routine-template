# onboard.sh — adding the Claude routine to existing repos

`onboard.sh` scaffolds the Claude routine into an **existing** repository. It's the counterpart to the "Use this template" button: the template button is for new repos created from scratch; this script is for repos that already exist and have their own code, history, and files.

## Where this script lives

This script lives in the `claude-routine-template` repo (the same repo whose files it copies). That co-location is deliberate: the script fetches a specific list of files from this template, and that list (the `TEMPLATE_FILES` array near the top of the script) must stay in sync with the files that actually exist in the template. Keeping the script and the template in one repo means a single commit updates both — you can't update the template and forget to update the script's file list.

The script does **not** copy itself or this doc into target repos — only the files in `TEMPLATE_FILES`. So onboarding a repo gets it the routine files, not the onboarding tooling.

## How to run it

```bash
# From anywhere, pointing at the repo you want to onboard:
/path/to/onboard.sh ~/code/my-existing-project

# Or clone the template repo and run from there:
git clone https://github.com/rsterenchak/claude-routine-template.git
cd claude-routine-template
./onboard.sh ~/code/my-existing-project
```

The script:
1. Validates the target is a git repo.
2. Detects the project's shape from its `package.json` (ESM vs CommonJS, working directory, source directory, test/build commands).
3. Shows you a plan: what it detected and which files it will create vs skip.
4. Waits for your confirmation. **Nothing is written until you say yes.**
5. Fetches the routine files from this template (current versions, via raw GitHub URLs) and writes only the ones that don't already exist.
6. Prints a checklist of remaining manual steps, with detected values pre-filled.

## What it will and won't do

**It will:**
- Create routine files that don't exist in the target (CLAUDE.md, .claude/*, workflows, the correct manifest variant).
- Detect ESM vs CommonJS and pick the right `gen-src-manifest` variant (`.cjs` for ESM, `.js` for CommonJS).
- Detect your working dir, source dir, and test/build commands and pre-fill them in the printed checklist.
- Guess your repo's `owner/name` from its git remote for the worker `ALLOWED_TARGETS` line.

**It won't:**
- Overwrite any existing file. If the target already has a `CLAUDE.md`, a workflow, or a `.claude/routine.md`, the script reports it as `skip` and leaves it untouched. You merge manually if needed.
- Touch your source code, package.json, or anything outside the routine files.
- Do the external setup (GitHub App, secrets, PAT, worker deploy) — those are manual steps it reminds you about, because they involve granting access you should confirm consciously.
- Fill in the `{{PLACEHOLDER}}` values inside the files. It detects and *suggests* them in the checklist, but you paste them in (so you can review first). This is intentional — auto-editing file contents is where silent mistakes hide.

## Requirements

- `bash`, `curl`, and standard unix tools (`grep`, `sed`, `find`). Present on any dev machine.
- Network access — the script fetches template files from `raw.githubusercontent.com`.
- This template repo must stay **public**. The script uses unauthenticated raw URLs; a private template would 404. If you ever make the template private, the script needs to switch to authenticated fetches (add a `gh api` or `curl` with a token).

## Maintaining the script as the template evolves

When you add, rename, or remove a file in this template repo, update the `TEMPLATE_FILES` array near the top of `onboard.sh` to match. If you forget, onboarding silently skips the new file (it can't fetch what it doesn't know about).

The `TEMPLATE_OWNER`, `TEMPLATE_REPO`, and `TEMPLATE_BRANCH` constants at the top control where the script fetches from. Update them if you move or rename the template repo.

## Detection limits (safe failures)

The detection is best-effort. When it can't determine something, it flags "not detected — fill in manually" rather than guessing wrong. Specifically:

- **Source dir** is detected by checking `src/`, `app/src/`, `lib/`, `source/` in order. Unusual layouts (monorepo `packages/*/src/`, `client/src/`, etc.) won't be found automatically — you fill in the prefix manually.
- **Test/build commands** are detected by grepping `package.json`'s scripts for common key names (`test:run`, `test:ci`, `test`, `build:prod`, `build`). Unusual script names fall back to manual.
- **Working dir** is found by locating `package.json` at the root or one level down. Deeper nesting isn't auto-detected.

In every case, the failure mode is "tells you to fill it in," never "writes a wrong value." Review the detected plan before confirming.

## First real run

The detection and skip-existing logic are well-tested, but the network fetch should be confirmed once against a throwaway target before you rely on it. Copy a repo you're about to onboard to a temp location, run the script against the copy, and confirm all the files land. If you see `FAILED (could not fetch from template)` lines, either the template repo path is wrong (check the constants at the top of the script) or a file in `TEMPLATE_FILES` doesn't actually exist in the template.

## After running

Follow the printed checklist. The script gets you the files and the detected values; the remaining work is:
1. Paste detected values into the `{{PLACEHOLDER}}` slots in CLAUDE.md, routine.md, and the workflows.
2. Configure the GitHub App, secrets, and PAT.
3. Add the repo to the worker's `ALLOWED_TARGETS` and deploy the worker.
4. Verify the manifest publishes and inject a test entry to confirm end-to-end.

The same checklist (with more detail) is in this repo's main `README.md` under "What to do after creating a repo from this template" — the steps are identical whether you came via the template button or this script.
