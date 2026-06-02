# CLAUDE.md

This file is the agent's primary architectural reference for this repository. It is read at the start of every Claude run, both by the in-app Claude assistant (Sonnet) when reasoning about this repo and by Claude Code (Opus) when implementing changes. Keep it current; if it drifts from the actual codebase, the agent's behavior drifts with it.

---

## Onboarding checklist (delete this section after you finish)

You just instantiated this repo from the `claude-routine-template`. Before this repo can participate in the Claude routine, complete these steps. Most are 30 seconds each.

**Files to fill in:**
- [ ] Replace `{{PROJECT_NAME}}` everywhere in this file with this project's name (the repo name is usually fine: e.g. `my-app`, `react-thing`, `cool-project`).
- [ ] Replace `{{PROJECT_DESCRIPTION}}` with 1-2 sentences about what this project is and what it does.
- [ ] Replace `{{STACK}}` with the technology stack (e.g. `vanilla JS + Webpack`, `React + Vite`, `Next.js`, `SvelteKit`).
- [ ] Replace `{{SRC_DIR}}` with the path from the repo root to the source directory (e.g. `src/` for most projects, `app/src/` if nested, `packages/web/src/` for monorepos).
- [ ] Replace `{{TEST_DIR}}` with the test directory path if applicable (e.g. `tests/`, `__tests__/`, `spec/`).
- [ ] Replace `{{TEST_COMMAND}}` with the command CI runs to test (e.g. `npm test`, `npm run test:ci`, `vitest run`).
- [ ] Replace `{{BUILD_COMMAND}}` with the command CI runs to build (e.g. `npm run build`, `vite build`).
- [ ] Replace `{{DEPLOY_TARGET}}` with where the project deploys (e.g. `GitHub Pages`, `Cloudflare Pages`, `Vercel`, or `none — library, no deploy`).

**Project-specific sections to fill in:**
- [ ] Fill in the "Key files in this repo" section with the load-bearing files in `{{SRC_DIR}}` and brief descriptions of each.
- [ ] Fill in any project-specific operating discipline that diverges from the defaults documented below.

**Workflow files to verify:**
- [ ] `.github/workflows/claude-run.yml` exists and references `CLAUDE_CODE_OAUTH_TOKEN` as a secret.
- [ ] `.github/workflows/test.yml` exists and runs `{{TEST_COMMAND}}`.
- [ ] `.github/workflows/deploy.yml` exists, runs `{{BUILD_COMMAND}}`, and includes a step to run `scripts/gen-src-manifest.{js|cjs}` so the in-app Claude assistant can attach files from this repo.
- [ ] Pick the right manifest generator variant:
  - If `package.json` has `"type": "module"` → use `scripts/gen-src-manifest.cjs`, delete the `.js` variant.
  - Otherwise → use `scripts/gen-src-manifest.js`, delete the `.cjs` variant.

**External setup:**
- [ ] Configure the Claude GitHub App to access this repo: https://github.com/apps/claude
- [ ] Add this repo to your GitHub PAT's access list: https://github.com/settings/personal-access-tokens
- [ ] Add a target to the `todo-injector-worker` repo's `ALLOWED_TARGETS` in `src/index.js`:
  ```
  { repo: "<owner>/<repo>", filePath: "TODO.md", srcPrefix: "{{SRC_DIR}}" },
  ```
- [ ] Deploy the worker: `cd todo-injector-worker && npm run deploy`.
- [ ] In the PWA's chat surface, switch the workspace pill to this repo and verify the file manifest loads (the picker should list files from `{{SRC_DIR}}`).
- [ ] Inject a small test entry (e.g. `- [ ] **[LOW]** Add a console.log to verify routine integration` — a trivial change you can revert). Verify `claude-run.yml` picks it up, opens a PR, and auto-merges. Once verified, you're integrated.

After all checkboxes are done, **delete this entire "Onboarding checklist" section** from CLAUDE.md. The rest of the document is the real reference.

---

## What this project is

**Project name:** {{PROJECT_NAME}}

**Description:** {{PROJECT_DESCRIPTION}}

**Stack:** {{STACK}}

**Source directory:** `{{SRC_DIR}}`

**Tests directory:** `{{TEST_DIR}}`

**Test command:** `{{TEST_COMMAND}}`

**Build command:** `{{BUILD_COMMAND}}`

**Deploys to:** {{DEPLOY_TARGET}}

---

## System overview — how the Claude routine works

This repo is wired into a broader automation pipeline. Understanding the pipeline matters because it shapes what kinds of changes Claude can make and how.

**The pipeline at a high level:**
1. A user (typically Robert) opens the Claude assistant in his PWA and authors a TODO entry through chat with Sonnet, or pastes one into `TODO.md` directly via GitHub.
2. The entry injects into this repo's `TODO.md` via the Cloudflare worker `todo-injector-worker`.
3. `claude-run.yml` dispatches automatically on inject, picking up the new entry.
4. Claude Code (Opus, via Max plan) runs in CI, reads the entry, implements the change, runs tests, opens a PR.
5. If tests pass, the PR auto-merges. `deploy.yml` then runs, building and deploying as configured.
6. The PWA's Runs tab tracks the PR's status via localStorage-backed polling.

**Two distinct Claude roles in this pipeline:**
- **Conversational planner (Sonnet, API-billed):** Helps authoring entries in the chat UI. Drafts entries, asks clarifying questions, enumerates cross-cutting concerns for structural UI changes.
- **Agentic builder (Opus, Max-plan):** Runs in CI to implement entries. Reads the codebase autonomously, makes changes, runs tests, opens PRs. Operates inside the `claude-run.yml` workflow.

---

## Repos and allowlist

The set of repos this routine can act on is configured in `todo-injector-worker/src/index.js` as `ALLOWED_TARGETS`. Each entry looks like:
```
{ repo: "owner/name", filePath: "TODO.md", srcPrefix: "src/" }
```

**Recipe for adding a new repo:**
1. Add the entry to `ALLOWED_TARGETS` in the worker. Choose `srcPrefix` based on where source files live (e.g. `src/` for root-level, `subdir/src/` for nested).
2. Ensure the GitHub PAT used by the worker has `Contents:write` and `Actions:read+write` scope on the new repo.
3. Add `scripts/gen-src-manifest.js` (or `.cjs` for ESM repos) to the new repo, plus a deploy.yml step that runs it.
4. Deploy the worker: `npm run deploy` from `todo-injector-worker`.

**Note on `.cjs` vs `.js`:** Use `.cjs` when the repo's `package.json` has `"type": "module"`. Otherwise use `.js`.

---

## Three context modes for the chat surface

The in-app Claude assistant's chat (Sonnet) gets context through three distinct mechanisms. Each has its own cost profile and trigger:

1. **ACTIVE REPO reframe (cheap):** When the user switches workspaces, the system prompt gets an "ACTIVE REPO" override that retargets Sonnet's framing toward the active repo. Typical input cost: ~1.7k tokens. Triggered by the `body.repo` field on every chat turn.

2. **Attached files (variable cost):** Files the user explicitly loads via the picker, or accepts via the one-tap suggestion chip. Loaded via the `body.attach_files` (manual, 40KB/file cap) or `body.suggested_attach_files` (suggestion-accepted, 20KB/file cap) field. Typical input cost: ~5-25k tokens depending on file count and size.

3. **Iterate seed (heavy):** Sent on turn 1 of an iterate conversation via `body.entry_id`. Loads diff + sliced post-merge code from the PR that shipped the originating entry. Typical input cost: ~12-20k tokens.

---

## Key files in this repo

> Fill this in with the actual load-bearing files. Aim for 1-line descriptions. Example structure:
>
> - `{{SRC_DIR}}/main.js` (or equivalent entry point) — what it does
> - `{{SRC_DIR}}/dataLayer.js` — data model / state — note if ALL mutations route through here
> - `{{SRC_DIR}}/components/Foo.jsx` — what it does
> - `{{TEST_DIR}}/dataLayer.test.js` — test coverage for the data layer
>
> Including this section honestly is high-leverage. Without it the agent has to grep blindly; with it the agent goes to the right file first.

---

## Hard rollback

If a shipped change is bad in a way fix-forward via iterate cannot quickly cure: open the offending PR in GitHub mobile or web, tap **Revert**, merge the revert PR. `deploy.yml` runs automatically and rollback ships in ~2 minutes.

**There is no in-app revert button by design.** ~95% of issues fix-forward cleanly through iterate, and an unused safety button decays. For the ~5% case, the manual revert path above is the answer.

**Warning when reverting via GitHub mobile:** revert ONLY the original feature PR, never a revert PR. Revert PRs share titles with their originals (`Revert "[Claude] feature: X"`), and reverting a revert *re-applies* the original change — easy to do by mistake at a glance.

---

## Worker location and routes

`todo-injector-worker` is a separate repo (not part of this one). It's deployed via `npm run deploy` (Wrangler).

**Routes the worker exposes:**
- `inject` — write an entry to `TODO.md`
- `dispatch` — start the `claude-run.yml` workflow
- `status` — poll a workflow run by `correlation_id`
- `read` — read `TODO.md`
- `chat` — Sonnet proxy; accepts `messages`, `entry_id`, `attach_files`, `suggested_attach_files`, `repo`, `telemetry`
- `resolve` — find a merged PR by its `<!-- id: ... -->` marker

**Important:** SYSTEM_PROMPT and ITERATE_PREAMBLE live in the worker, NOT in this repo. Changes to chat behavior require editing and redeploying the worker, not the repo.

---

## Instrumentation & operating lessons

The build relies on a few verification habits worth knowing:

1. **`npx wrangler tail`** shows per-turn chat usage as `chat usage { iterate_seed: true|false, input_tokens, output_tokens, suggested_count }`. Healthy iterate-seed turn is ~12-20k tokens; follow-ups ~1-2k.
2. **DevTools console** for service worker state:
   ```js
   navigator.serviceWorker.getRegistration().then(r => console.log({
     waiting: !!r.waiting,
     installing: !!r.installing,
     active: r.active?.scriptURL
   }))
   ```
3. **View-source on live HTML** to verify content-hashed bundle filenames (proves SW revisions on each deploy, prevents the "byte-identical SW" stale-cache trap).
4. **Probe-injection into `todoapp_claudeRuns`** localStorage for testing reconcile logic.

**Operating principle: "Green Shipped status + a changelog entry is NOT proof a fix worked — only behavior on real data is. Always instrument, never trust the surface."**

Specifically: retroactive promotion and run dedup both have regression tests because the "no-op pattern" (agent ships an entry without doing the real work, but tests pass because they're too loose) shipped once. We don't trust ourselves to catch it by code review alone.

---

## Cross-cutting verification discipline for structural UI changes

When describing a UI move/relocate/restructure in chat, the system prompt instructs the chat agent (Sonnet) to lead with **proactive enumeration** of cross-cutting concerns BEFORE drafting an entry. The categories Sonnet enumerates:

1. Direct behaviors on the element (listeners, state reads, ARIA wiring)
2. Paired UI (popovers, dropdowns, menus that appear *near* the element — they have a spatial contract)
3. Mount-path-registered behaviors (listeners set up during the element's old parent's build function — they silently don't fire after a move)
4. DOM-traversal dependencies (queries from the element's old parent or siblings)
5. Architectural role conflations (elements that are both display and control)

**User's role in the flow:** Verify the enumeration is complete, add anything Sonnet missed from local knowledge, confirm. Outcome: defensive entries with explicit, verifiable acceptance criteria.

**Failure modes this defends against:** structural moves of UI elements that silently break load-bearing flows (e.g. the workspace pill move that broke injection by detaching state wiring; the file picker button move that orphaned its panel at the old location; the file picker panel move that lost its outside-click listener). After the prompt addition, subsequent structural moves shipped clean because their entries named these concerns as explicit acceptance criteria.

---

## Entry format

Entries in `TODO.md` follow a strict format because an automated parser reads them:
```
- [ ] **[PRIORITY]** Imperative verb + specific change
  - Type: bug | feature
  - Description: 2-4 concrete sentences — what's wrong or what to build, expected behavior, likely code locations.
  - File: `{{SRC_DIR}}/main.js`, `{{SRC_DIR}}/style.css`
  - Completed: YYYY-MM-DD (PR #<number>)
```

**Priority levels:**
- `**[HIGH]**` — broken functionality, blocking
- `**[MEDIUM]**` — noticeable UX issue or moderate feature (the common case)
- `**[LOW]**` — cosmetic / nice-to-have

**Critical format rules:**
- Priority MUST be inside literal square brackets within bold markers: `**[HIGH]**`, NOT `**HIGH**`. A non-bracketed priority is a parse failure — the parser silently downgrades to MEDIUM.
- File paths MUST be full repo-relative paths, never bare filenames.
- Title is always imperative and specific (e.g. "Fix font size growing after deletion"), never a noun phrase.

---

## Operating principles worth banking

**Don't pre-add prompt clauses for hypothetical failures.** Add them when a specific pattern bites and add only what would catch that specific pattern. Pre-adding clauses produces prompt bloat that degrades response quality.

**Adjacent UI changes always look guilty when behavior shifts.** Verify the actual cause before assuming a recent move broke something — workflow gaps and timing coincidences look identical to regressions from the outside.

**Symmetric round-trips matter.** UTF-8 safety on one half of a read/write round trip is worse than no UTF-8 handling — lopsided correctness compounds invisibly. (See: the encoding bug that bloated TODO.md exponentially because read-side `atob` was Latin-1 while write-side `TextEncoder` was UTF-8.)

**Self-report of own context is unreliable.** Trust observable instruments (`wrangler tail` token counts, actual diff content, real behavior on real data) over claims about what context was used.

**Each prompt clause is earned by observed failures, not hypothesized ones.** When a clause is added, it includes a concrete past failure as a motivating example. This prevents the prompt from drifting into checklist soup.
