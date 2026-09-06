# CLAUDE.md

This file is the agent's primary architectural reference for this repository. It is read at the start of every Claude run, both by the in-app Claude assistant (Sonnet) when reasoning about this repo and by Claude Code (Opus) when implementing changes. Keep it current; if it drifts from the actual codebase, the agent's behavior drifts with it.

---

## Onboarding checklist (delete this section after you finish)

`onboard.sh` already did the mechanical part: every `{{…}}` placeholder in this
file is filled, the workflows exist, the manifest variant is picked, and this repo
is registered as an inject target. Two things it cannot do, because they need
someone who knows the code:

- [ ] Fill in **Key files in this repo** below — the load-bearing files under
      `{{SRC_DIR}}`, one line each. Without it every run greps blindly; with it
      the run goes to the right file first.
- [ ] Fill in the **conventions** a run must honor that the code does not make
      obvious: where files live if not under `{{SRC_DIR}}`, what must never be
      introduced, how work is split. On coursework, put these in the Assignment
      context section and include the assignment's own rules (a single
      stylesheet, no frameworks, one entry per graded requirement, and so on).

If any `{{…}}` remains anywhere in this file, `onboard.sh` missed it — fill it by
hand. Then delete this section: the row Check in the PWA warns while it is still
here, so a run never reads a stub thinking it is the reference.

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

<!-- =========================== ASSIGNMENT CONTEXT — fill in if this is coursework =========================== -->
<!-- This block is for coursework or graded assignments. If this  -->
<!-- repo is a personal project, delete the entire block (from    -->
<!-- the ASSIGNMENT CONTEXT marker above to the END marker below).-->
<!-- The chat assistant auto-loads CLAUDE.md every turn, so once   -->
<!-- filled, these constraints persist across the whole            -->
<!-- assignment — you don't have to re-paste the spec each time.   -->

## Assignment requirements

<!-- Paste or summarize the assignment spec / rubric / problem    -->
<!-- statement here. What does this program need to do? What       -->
<!-- inputs does it accept, what outputs does it produce, what     -->
<!-- edge cases must it handle? Be specific — Sonnet and the       -->
<!-- claude-run agent will both read this verbatim.                -->

(replace this line with the assignment spec)

## Constraints and conventions for this assignment

<!-- Constraints specific to this course / professor / assignment. -->
<!-- Examples: "Must use Dictionary, not List", "No LINQ", "Input  -->
<!-- validation per spec section 2.3", "All public methods must    -->
<!-- have XML doc comments", "Use only language features covered   -->
<!-- in lectures through Week 5".                                  -->
<!--                                                                -->
<!-- These are honored automatically by claude-run when            -->
<!-- implementing entries, because the agent reads CLAUDE.md as    -->
<!-- part of its context. You don't have to remind it per-entry.   -->

(list constraints, or write "none" if there are none)

## Submission and grading

<!-- Due date, submission format (zip? PR? canvas upload?), what's -->
<!-- being graded (correctness only? style? tests? performance?),  -->
<!-- and any submission-specific notes.                            -->

(fill in submission details)
<!-- =========================== END ASSIGNMENT CONTEXT =========================== -->

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

## Repos and the inject registry

The set of repos this routine can act on lives in the Supabase `inject_targets` table, not in the Worker's code. Each row carries `repo`, `file_path` (`TODO.md`), `src_prefix`, `shape`, and `enabled`; the Worker's `resolveTarget` reads the table live, so adding a repo needs no Worker redeploy.

**Recipe for adding a new repo:**
1. Add an `inject_targets` row — in the PWA via **Inject settings → + Add target**. Choose `src_prefix` by where source lives: `src/` for root-level, `subdir/src/` for nested, `""` for files at the repo root. (Onboarding through CI inserts this row for you.)
2. Ensure the GitHub PAT used by the worker has `Contents:write` and `Actions:read+write` scope on the new repo.
3. Add `scripts/gen-src-manifest.js` (or `.cjs` for ESM repos) to the new repo, plus the workflow step that runs it.

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
> - `{{SRC_DIR}}main.js` (or equivalent entry point) — what it does
> - `{{SRC_DIR}}dataLayer.js` — data model / state — note if ALL mutations route through here
> - `{{SRC_DIR}}components/Foo.jsx` — what it does
> - `{{TEST_DIR}}dataLayer.test.js` — test coverage for the data layer
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
  - File: `{{SRC_DIR}}main.js`, `{{SRC_DIR}}style.css`
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

## Placeholder text

- Any generated prose longer than one sentence (page copy, section descriptions,
  marketing text, sample paragraphs, about/intro blocks) must be lorem ipsum,
  not real content.
- Rationale: real copy is authored manually and swapped in at will later.
  Agent-written prose creates review burden and risks shipping unvetted wording.
  Do not "improve" lorem ipsum blocks into real text — that is a regression,
  not a fix.
- Exception: single-sentence strings stay real and meaningful — labels, buttons,
  headings, nav items, alt text, error messages, form hints, table headers.
- On coursework repos: lorem ipsum is a build-time convention only. Real content
  must be swapped in before submission — evaluators grade the copy. Treat the
  swap as a mandatory pre-submission step.

---

## Operating principles worth banking

**Don't pre-add prompt clauses for hypothetical failures.** Add them when a specific pattern bites and add only what would catch that specific pattern. Pre-adding clauses produces prompt bloat that degrades response quality.

**Adjacent UI changes always look guilty when behavior shifts.** Verify the actual cause before assuming a recent move broke something — workflow gaps and timing coincidences look identical to regressions from the outside.

**Symmetric round-trips matter.** UTF-8 safety on one half of a read/write round trip is worse than no UTF-8 handling — lopsided correctness compounds invisibly. (See: the encoding bug that bloated TODO.md exponentially because read-side `atob` was Latin-1 while write-side `TextEncoder` was UTF-8.)

**Self-report of own context is unreliable.** Trust observable instruments (`wrangler tail` token counts, actual diff content, real behavior on real data) over claims about what context was used.

**Each prompt clause is earned by observed failures, not hypothesized ones.** When a clause is added, it includes a concrete past failure as a motivating example. This prevents the prompt from drifting into checklist soup.
