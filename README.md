# Claude routine template

A GitHub template repo that scaffolds the file structure for participating in Robert's Claude routine — an automation pipeline where TODO entries get implemented by Claude Code (Opus) in CI, with a conversational planner (Sonnet) in a PWA assisting with authoring.

If you're creating a new repo that should be part of this routine, use the **"Use this template"** button on GitHub to start from this scaffolding rather than copying files manually.

---

## What's in this template

```
.
├── CLAUDE.md                       # Architecture reference + onboarding checklist
├── TODO.md                         # The backlog file the routine reads
├── README.md                       # This file (delete or replace after onboarding)
├── .claude/
│   ├── routine-base.md             # Universal routine discipline (identical across projects)
│   └── routine.md                  # Project-specific commands and conventions (fill in)
├── .github/
│   └── workflows/
│       ├── claude-run.yml          # Dispatches Claude Code on TODO.md entries
│       ├── test.yml                # CI test runner
│       └── deploy.yml              # Build + manifest + deploy
└── scripts/
    ├── gen-src-manifest.js         # For CommonJS projects — keep ONE of these
    └── gen-src-manifest.cjs        # For ESM projects ("type": "module") — keep ONE of these
```

Every file has template instantiation notes at the top explaining what to fill in and what to leave alone. Read those before editing.

---

## What to do after creating a repo from this template

There are roughly **8-10 steps** depending on your project shape. None are hard; most take less than a minute. The total time is dominated by waiting on deploys and external account configurations, not by your active typing time.

### Step 1 — Pick a manifest generator variant

In `scripts/`, you have both `gen-src-manifest.js` and `gen-src-manifest.cjs`. **Keep one, delete the other.** The decision rule:

- Open `package.json`. Does it have `"type": "module"`?
  - **Yes** → keep the `.cjs` variant, delete the `.js`
  - **No** (or the field is absent) → keep the `.js` variant, delete the `.cjs`

Why: Node.js enforces this at runtime. If you use the wrong extension, the script crashes with `require is not defined` (in ESM projects) or treats CommonJS as ESM (in CommonJS projects). The two files have identical content; only the extension differs.

### Step 2 — Update CLAUDE.md

Open `CLAUDE.md` and follow its onboarding checklist (it's at the top of the file). Specifically:

- Replace every `{{PLACEHOLDER}}` with the actual value for your project
- Fill in the "Key files in this repo" section with the load-bearing files
- After everything is filled in, **delete the onboarding checklist section** so future readers see clean documentation, not setup instructions

### Step 3 — Update `.claude/routine.md`

Open `.claude/routine.md` and fill in the project-specific commands (test command, build command, install command, etc.). The file has comment blocks showing what to put in each section. Leave `routine-base.md` alone — it's universal.

### Step 4 — Update workflow files

Open each of:
- `.github/workflows/test.yml`
- `.github/workflows/deploy.yml`

Each file has template instantiation notes at the top. Fill in:
- `{{WORKING_DIR}}` — the path from the repo root to where `package.json` lives. If `package.json` is at the root, set to `.` and remove the `working-directory:` lines.
- Test command (in `test.yml`), build command + deploy step + secrets (in `deploy.yml`)
- For `deploy.yml`: if you're not deploying to GitHub Pages, swap the deploy step for the relevant alternative (Cloudflare Pages, Vercel, Netlify, or remove the step entirely if this is a library / non-deployable project)

`claude-run.yml` should not need changes; its template note explains the one secret you need to configure (Step 6 below).

### Step 5 — Configure the Claude GitHub App for this repo

Visit https://github.com/apps/claude and grant the app access to your new repo. The app needs to read and write code, open PRs, and post comments.

### Step 6 — Configure secrets in this repo

Go to your new repo's **Settings → Secrets and variables → Actions** and add:

- **`CLAUDE_CODE_OAUTH_TOKEN`** — your Claude Code Pro/Max subscription OAuth token (see [Claude Code docs](https://docs.claude.com/en/docs/claude-code) for how to obtain). Required by `claude-run.yml`.
- Any **build-time secrets** your project needs (e.g. `GOOGLE_OAUTH_CLIENT_ID`, deploy API keys). These are referenced in `deploy.yml`'s `env:` block under the Build step.

### Step 7 — Update your GitHub PAT for the worker

If you have an existing `todo-injector-worker` deployment, add this repo to your PAT's access list:
- Go to https://github.com/settings/personal-access-tokens (or classic tokens, depending on which kind you use)
- Find the PAT used by the worker
- Add this repo to its repository access list
- Required scopes: `Contents:write` and `Actions:read+write`

### Step 8 — Add this repo to the worker's `ALLOWED_TARGETS`

In `todo-injector-worker/src/index.js`, add an entry to `ALLOWED_TARGETS`:

```js
{ repo: "<your-username>/<your-repo>", filePath: "TODO.md", srcPrefix: "<src dir>/" }
```

Where `srcPrefix` is the path from your repo root to where source files live (e.g. `src/`, `app/src/`, or `<working-dir>/src/`).

Then deploy the worker: `cd todo-injector-worker && npm run deploy`.

### Step 9 — Verify the manifest publishes

Push a commit (any commit — the template's initial commit counts). After `deploy.yml` runs, verify that `https://<your-username>.github.io/<your-repo>/src-manifest.json` (or wherever your deploy publishes static assets) returns valid JSON with a `files` array.

If this fails, the in-app Claude assistant's file picker won't list your repo's files. Most common cause: the `working-directory` in `deploy.yml`'s "Generate source manifest" step doesn't match where the script actually lives.

### Step 10 — Test injection end-to-end

In the PWA's chat surface, switch the workspace pill to this new repo. Then inject a trivial test entry:

```md
- [ ] **[LOW]** Add a comment to README.md saying "Claude routine integration verified"
  - Type: feature
  - Description: One-line change — add a comment at the top of README.md confirming this repo successfully participates in the Claude routine. This is a smoke test for the integration.
  - File: `README.md`
  - Completed: YYYY-MM-DD (PR #<number>)
```

If `claude-run.yml` dispatches, the PR opens within a few minutes, tests pass, and the PR auto-merges — you're integrated. If anything goes wrong, the failure mode tells you which step needs revisiting (most commonly Steps 5, 6, or 8).

### Step 11 — Replace this README

Delete this `README.md` file or replace it with one describing your actual project. Future visitors should see your project's documentation, not the template's onboarding guide.

---

## After onboarding

Once you've completed all the steps above:

- **`CLAUDE.md`** is the agent's primary reference. Keep it updated as your project evolves.
- **`TODO.md`** is the backlog. Add entries via the PWA's chat surface, or paste directly.
- **`.claude/routine.md`** is the project-specific operational doc. Update when commands change.
- **`.claude/routine-base.md`** is universal — don't edit it per-project. If you find yourself wanting to change it, propose the change upstream so all repos benefit.

The routine handles the rest: entries get implemented, PRs get opened and merged, deploys ship automatically.

---

## Troubleshooting common onboarding issues

**"My PR opens but auto-merge doesn't fire."**
- Check branch protection rules on `main`. Auto-merge requires the right combination of "Allow auto-merge" enabled at repo level + branch protection rules that permit auto-merge.
- If you have required checks, make sure `test.yml` is in the required check list.

**"The file picker in the PWA shows 'No files available' for my repo."**
- The manifest isn't publishing. Check that `deploy.yml` ran successfully and that the `gen-src-manifest` step succeeded. Verify the manifest URL returns JSON.
- If the manifest exists but is empty, the script's `srcDir` resolution probably points at the wrong directory. Check `gen-src-manifest.{js,cjs}` and confirm `path.resolve(__dirname, '..', 'src')` actually points at your source directory.

**"Files attach but Claude says 'file not found.'"**
- The worker's `srcPrefix` is wrong for this repo. The manifest publishes bare filenames (e.g. `main.js`), but the worker needs to know to prepend `srcPrefix` (e.g. `src/main.js`) to construct the correct raw.githubusercontent URL.
- Check the worker's `ALLOWED_TARGETS` entry for this repo and confirm `srcPrefix` matches where source actually lives.

**"`claude-run.yml` fails with 'authentication error.'"**
- The `CLAUDE_CODE_OAUTH_TOKEN` secret is missing or expired in this repo. Re-add it via Settings → Secrets and variables → Actions.

**"Injection works but `claude-run.yml` doesn't trigger."**
- The worker's GitHub PAT either doesn't have access to this repo or lacks `Actions:read+write` scope. Check the PAT's repository access list and scopes.

---

## Why this template exists

The Claude routine has 10+ moving parts that have to be configured consistently across repos. Onboarding from scratch each time meant re-deriving "what files go where" and "what commands need to be wired up." This template captures the answers once so subsequent onboardings are mechanical rather than archaeological.

If you're adapting the routine to a project shape this template doesn't cover well, the right move is to onboard once, learn what's missing, and update the template — not to fork the template per-project.
