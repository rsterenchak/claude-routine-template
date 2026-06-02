# Routine — project-specific operations

This file documents the project-specific commands, conventions, and quirks for **{{PROJECT_NAME}}**. It supplements `routine-base.md` (which has the universal discipline) with project-specific details Claude runs need to know.

If `routine-base.md` is "how Claude runs work in general," this file is "how Claude runs work for *this* repo specifically."

---

## Project identity

**Name:** {{PROJECT_NAME}}

**Description:** {{PROJECT_DESCRIPTION}}

**Stack:** {{STACK}}

---

## Working directories

- **Source code:** `{{SRC_DIR}}`
- **Tests:** `{{TEST_DIR}}`
- **Build output:** `{{BUILD_DIR}}` (typically `dist/` or `build/`)

When the user references a file by bare name (e.g. `main.js`), it lives in `{{SRC_DIR}}/`. When they reference a test file (e.g. `main.test.js`), it lives in `{{TEST_DIR}}/`.

---

## Commands the routine runs

**Install dependencies (if needed before tests/build):**
```
{{INSTALL_COMMAND}}
```

**Run tests:**
```
{{TEST_COMMAND}}
```

**Build:**
```
{{BUILD_COMMAND}}
```

**Deploy target:** {{DEPLOY_TARGET}}

The `deploy.yml` workflow handles deployment automatically on merges to `main`. Claude runs do not need to invoke deploy directly.

---

## Project-specific conventions

> Fill this section with anything about this project that diverges from the universal discipline in `routine-base.md`. Examples of what might go here:
>
> - **Data layer routing:** "All data-model mutations must go through `{{SRC_DIR}}/dataLayer.js`. Direct localStorage writes are prohibited."
> - **Code style:** "This project uses tabs, not spaces. ESLint and Prettier configs are authoritative."
> - **Test patterns:** "Tests use Vitest with jsdom. Mock browser APIs at the module level, not inline."
> - **Known fragile files:** "{{SRC_DIR}}/legacy.js is in active rewrite — changes there require extra care."
> - **Files that look similar but aren't:** "Don't confuse `helpers.js` (general utilities) with `helpers-internal.js` (private to the data layer)."
>
> If nothing project-specific exists, write "No project-specific conventions beyond the universal discipline in routine-base.md."

---

## Known fragile areas

> Document any code paths that have caused regressions before, or that require specific care. Examples:
>
> - "{{SRC_DIR}}/main.js evaluates module-level code twice due to webpack entry-bundle structure. Use one-shot guards for listener registration."
> - "Index-based deletion is unreliable due to array-index drift; use title-based or id-based deletion."
> - "INSERT must complete before UPDATE for entity X — async ordering matters."
>
> If no known fragile areas, write "No known fragile areas. This section grows as the project ships entries and learns from regressions."

---

## Manifest generator

This project publishes `src-manifest.json` to its deployed site so the in-app Claude assistant's file picker can discover its source files. The generator runs as part of `deploy.yml`.

**Variant:** {{MANIFEST_VARIANT}} (either `gen-src-manifest.js` for CommonJS projects or `gen-src-manifest.cjs` for ESM projects with `"type": "module"` in package.json)

The manifest publishes bare filenames; the worker's `resolveAttachPath` prepends the configured `srcPrefix` to construct full repo-relative paths at fetch time.

---

## Notes for the in-app Claude assistant (Sonnet)

When Sonnet is conversationally reasoning about this repo, the key things to keep in mind:

> Document the architectural shape Sonnet should know. Examples:
>
> - "{{PROJECT_NAME}} is a single-page app; routing is hash-based via {{ROUTER_FILE}}."
> - "The main state container is {{STATE_FILE}} — global state mutations flow through there."
> - "UI components live in {{SRC_DIR}}/components/; pages in {{SRC_DIR}}/pages/."
>
> The goal is that Sonnet, when asked about this project, has enough architectural context to engage substantively without needing to read every file.

---

## Notes for Opus (Claude Code in CI)

When Opus is implementing an entry, the key things to know:

> Document the implementation-level shape Opus needs. Examples:
>
> - "Run `{{TEST_COMMAND}}` before opening the PR — CI will catch failures but the agent should not rely on CI to find them."
> - "Don't modify the build pipeline ({{BUILD_FILE}}) without an explicit entry asking for it."
> - "When the entry says 'add a test in X.test.js,' the test must actually fail against a broken implementation."
>
> The goal is that Opus, when shipping a PR, has enough context to ship correctly the first time.

---

## Deployment quirks (if any)

> Document anything weird about how this project deploys. Examples:
>
> - "First-time deploys to GitHub Pages require manually enabling Pages in repo settings."
> - "Cloudflare Pages requires a `wrangler.toml` at the repo root."
> - "Vercel deploy preview URLs are non-deterministic; reference the production URL only."
>
> If deployment is fully automated and unsurprising, write "No deployment quirks. `deploy.yml` handles everything."
