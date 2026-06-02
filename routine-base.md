# Routine base — operating discipline for Claude runs

This file documents the universal operating principles for any Claude run in this routine. It is identical across all repositories that participate in the system; project-specific commands and conventions live in `routine.md`.

Read this before every action. Both `routine.md` and `CLAUDE.md` build on top of these principles.

---

## What a Claude run does

A Claude run is triggered by an entry in `TODO.md` and executes via `claude-run.yml`. The agent (Opus, via Max plan) reads the entry, implements the change, runs tests, and opens a PR. If tests pass, the PR auto-merges and deploys.

Each run is single-shot: there is no multi-turn agent loop. The entry describes the change completely; the run executes it. Conversational refinement happens in the in-app Claude assistant (Sonnet) **before** the entry is finalized — by the time a run starts, the spec is locked.

---

## How to read an entry

Entries in `TODO.md` follow a strict format:
```
- [ ] **[PRIORITY]** Imperative title
  - Type: bug | feature
  - Description: prose explaining what to change, why, expected behavior, and likely code locations.
  - File: `path/to/file.js`, `path/to/another.js`
  - Completed: YYYY-MM-DD (PR #<number>)
```

**Critical parsing rules:**
- The `**[PRIORITY]**` tag uses literal square brackets inside bold markers. `**[HIGH]**` is correct; `**HIGH**` is a parse failure and will silently downgrade to MEDIUM.
- Multiple files in the `File:` line are comma-separated, each backtick-wrapped, each a full repo-relative path.
- The `Completed:` line is a placeholder until the routine fills it in on PR merge.

**Treat the entry as the source of truth.** If the entry says "Move X from A to B," that's the change. Don't interpret it more broadly or take adjacent improvements along for the ride — the entry's scope is the spec.

---

## The cardinal rule — implement only what is named

The single most important discipline: **do not exceed the entry's scope.**

The entry's `Description` enumerates the change, and (especially for structural UI moves) lists cross-cutting concerns as explicit acceptance criteria. Every item on that list must be addressed. Nothing **else** should be changed.

**Specifically:**
- Do not refactor adjacent code "while you're there."
- Do not add features the entry didn't request, even if they seem obviously useful.
- Do not fix unrelated bugs you happen to notice; file them as separate entries.
- Do not rename functions or restructure code unless the entry explicitly says to.
- Do not skip acceptance criteria because they "seem unnecessary."

If you find yourself wanting to do more than the entry specifies, the right move is to **finish the entry exactly as specified** and **note the additional opportunity in the PR body** ("While implementing this I noticed X could also benefit from Y — recommending a follow-up entry"). The user decides if a follow-up entry should be drafted.

This rule exists because of repeated past failures where over-scope work caused regressions that took more effort to fix-forward than the original entry was worth.

---

## Cross-cutting acceptance criteria — what to take seriously

When an entry's `Description` enumerates acceptance criteria (typically labeled `(a)`, `(b)`, `(c)` etc.), each is a **named behavior that must continue to work** after the change. These are not suggestions; they are gates on the PR.

**Common categories the entry may name:**

1. **Direct behaviors on the element** — listeners, state reads, ARIA wiring attached to the changed code.
2. **Paired UI elements** — popovers, dropdowns, panels, tooltips that appear *near* the changed element. They have a spatial contract that breaks if you only move one half.
3. **Mount-path-registered behaviors** — listeners or setup that runs in the *function that builds the changed element's old parent*, not on the element itself. When the element moves to a new parent, the old setup function silently doesn't run for the new context.
4. **DOM-traversal dependencies** — queries from the element's old parent or siblings (CSS selectors like `.oldParent > .element`, JS like `element.parentElement.method(...)`). When the parent changes, these silently stop matching.
5. **Architectural role conflations** — elements that are both display and control (selecting a value and reflecting the current value). Both roles must survive the change.

**For each enumerated criterion in the entry:**
- Implement the change such that the behavior continues to work.
- If the entry mentions tests, ensure the test asserts the behavior.
- If the criterion is ambiguous or appears impossible, **stop and ask via PR comment rather than guessing**.

---

## Testing discipline

**Run the project's tests before opening the PR.** If they fail, fix what you broke. Do not open a PR with failing tests.

**If the entry says "add a test for X," the test must:**
1. Actually exist in the test file.
2. Actually assert the behavior X (not a paraphrase or weaker version).
3. Actually fail if the implementation is broken. Verify this by mentally walking the test against a broken implementation; if the test would pass on a no-op, the test is too weak.

**Test failures the no-op pattern produces** — these are caught by tests but only if the tests are specific enough:
- Asserting a function "got called" instead of asserting "got called with the right arguments"
- Asserting a value "exists" instead of asserting "equals the expected content"
- Asserting "no error thrown" instead of "produced the correct side effect"

If you find an existing test in this category, the entry's spec may have asked you to tighten it. Read carefully.

---

## PR opening discipline

**PR title:** `[Claude] feature: <title>` or `[Claude] bug: <title>` — matching the entry's `Type:` line.

**PR body:** Include the entry's `<!-- id: ... -->` marker so the system can resolve this PR back to the entry. Do not invent the marker — it's already in `TODO.md` if the entry has one; if no marker, omit the line rather than fabricate.

**One PR per entry.** If an entry is large enough that you genuinely cannot complete it in one PR, **stop and request the entry be split** rather than opening a partial PR. Half-shipped entries leave the system in confusing intermediate states.

**The PR should be reviewable.** That means:
- Diff scoped to the entry's `File:` list (no incidental drift)
- Clear commit messages
- Test results visible
- No dead code, no commented-out blocks, no debug prints left in

---

## Honest failure modes — the no-op pattern

The system has seen this pattern enough times to name it explicitly: **an entry ships but the work wasn't actually done.** The PR opens, tests pass (because they were too loose), the entry checks off as Completed — but the behavior didn't actually change. Or it changed in form (the file was modified) but not in substance (the modification didn't accomplish the goal).

**This happens when:**
- The agent shortcuts a difficult acceptance criterion ("this is probably fine without it")
- The test is paraphrased instead of asserting the real behavior
- The implementation is structurally similar to the entry but functionally inert
- The change is committed but a related file (config, test, deploy) wasn't updated to match

**To avoid this:**
- Verify each acceptance criterion mentally before merging
- If a test seems redundant, write it anyway — the spec asked for it
- Read the PR's diff before approving it as if you were the reviewer
- If implementation feels "close enough but not quite right," it's wrong — finish it

---

## When to halt and ask vs proceed

**Proceed without asking when:**
- The entry's spec is clear and complete
- Acceptance criteria are unambiguous
- Implementation path is obvious from the codebase

**Halt and ask (via PR comment) when:**
- An acceptance criterion contradicts another
- The entry references a file or function that doesn't exist
- Implementing the change would require breaking something the entry didn't authorize
- The expected behavior is ambiguous and your interpretation could produce one of multiple valid outcomes

When halting, leave clear questions. Don't write speculation about what the user might mean; ask what they meant.

---

## What happens after merge

The routine reconciles run status by querying the GitHub API for the PR's state. Merged PRs become Shipped runs in the user's PWA Runs tab. Failed PRs become Failed runs. Unknown states become Unknown.

If a run reaches Shipped but the behavior didn't actually change (the no-op pattern), the user catches it during use. The fix is a follow-up entry. **Do not pre-emptively claim "this is done correctly" — the user verifies; you ship and move on.**
