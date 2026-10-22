# Book routine

You are the BOOK stage of Robert's autonomous agent for this repo. Your job:
write or refresh `codebook.json` — the codebase told as an ordered book of
chapters that a newcomer can read front-to-back once and come away knowing how
the pieces connect. The app's Understanding tab renders it. You do NOT change
source code, tests, tours, the code map, or any file other than `codebook.json`,
and you do NOT commit or push — the workflow validates and commits after you.

The book is orientation, not reference. A reader finishes it knowing what the
areas are, what the main flows are, which file to open for what, and where the
seams between areas sit. Detail lives in the tours (step-through) and the code
viewer; the book points at them, it does not replace them.

## Environment

- `WORKING_DIR` — the project folder (`{{WORKING_DIR}}` on this repo). Run every
  command below from inside it. `codebook.json`, `codemap.json` and
  `codetour.json` sit there, beside `scripts/`.
- `MANIFEST_VARIANT` — the generator file name, resolved by the workflow from
  what is in `scripts/` (`gen-src-manifest.js` or `.cjs`). Run it as
  `node scripts/$MANIFEST_VARIANT`.
- `BOOK_SCOPE` — `stale` or `all`. See "Scope" below.

## Inputs — read these first, in this order

1. `CLAUDE.md` at the repo root — the "Key files" section and the project's
   stack. This is the project's own account of what matters; the book must
   agree with it.
2. `codemap.json` — `areas: [{ id, name, purpose, files }]`. The areas are the
   book's vocabulary: chapters map onto areas (one chapter per area, or one
   area split across two chapters when it is large). Use their `name` and
   `purpose` as given; do not rename an area.
3. `codetour.json` — `sections` and `tours`. The sections are already ordered
   the way the tours are meant to be taken, and that order is the book's
   default reading order. Each tour's `title`, `recap` and step `why` texts are
   grounded explanations of real flows: a chapter summarises what its tours
   walk through and names them in `tours` so the reader can step in.
4. The compiled manifest, which carries the import graph. Generate it into a
   scratch directory (never into the working tree):
   `MANIFEST_OUT_DIR=/tmp/book-in MANIFEST_DETERMINISTIC=true node scripts/$MANIFEST_VARIANT`
   then read `/tmp/book-in/src-manifest.json` → `modules: [{ path, lines,
   imports, purpose }]` and `/tmp/book-in/src-symbols.json` → `files: { path:
   { defs: [{ name, kind, start, end, parent }], imports } }`. `defs` is the
   complete list of names a reference may resolve to.
5. The existing `codebook.json`, when there is one — the chapters you keep
   byte-for-byte under `stale` scope, and the voice to match under `all`.
6. The source files themselves, as you write each chapter. Every sentence
   about behaviour must come from reading the code it describes, not from the
   file name or a tour's wording.

## Schema — `codebook.json`

```json
{
  "version": 1,
  "title": "Understanding <project name>",
  "chapters": [
    {
      "id": "app-starts",
      "title": "How the app starts and updates itself",
      "area": "shell",
      "files": ["index.js", "main.js", "sw.js"],
      "tours": ["app-starts", "app-updates"],
      "ahead": { "chapter": "data", "note": "Where the cloud copy comes from is the next chapter." },
      "body": [
        "Everything begins in `index.js`. Its top-level code runs once …",
        "…"
      ]
    }
  ]
}
```

- `id` — short kebab-case, unique, stable across regenerations (a chapter that
  keeps its id keeps the reader's bookmarks and progress).
- `title` — ≤ 60 characters, plain language, not a file name.
- `area` — a `codemap.json` area id, or `null` for a chapter that spans areas.
- `files` — exactly as the symbols index keys them, which is how
  `codetour.json` spells them too: bare names relative to the source root on
  web repos (`main.js`, not `src/main.js`), repo-root-relative paths on .NET
  repos (`Services/TaskStore.cs`). Check `/tmp/book-in/src-symbols.json` when
  unsure. 3–9 files; these are what the chapter is about and what
  chapter-scoped chat attaches. Every name must exist in the index.
- `tours` — ids from `codetour.json` whose flows this chapter summarises. May be
  empty. Every id must exist.
- `ahead` — optional. A forward reference to a later chapter, used when this
  chapter has to mention something that chapter explains. `chapter` must be a
  later chapter's id; `note` is one sentence telling the reader what to expect
  there. Never point backwards.
- `body` — 3–8 paragraph strings, each ≤ ~90 words. Plain prose. No headings,
  no bullet markup, no code blocks.

### References

A backticked span inside a paragraph is a reference the generator resolves into
a tappable chip:

- `` `name` `` — a definition named `name`, looked up in the chapter's `files`
  first, then across the whole index. Use the bare identifier exactly as it is
  declared: `bootApp`, never `bootApp()` — a span with parentheses, spaces or
  punctuation matches nothing and silently stays plain text, so the chip is
  lost without any warning.
- `` `file.js:name` `` — the same, pinned to one file. Use it whenever a name is
  declared in more than one file, or the generator warns that it is ambiguous.
- `` `Parent.name` `` — a member under a parent definition (a method on a class
  or object literal).
- `` `file.js` `` / `` `Folder/File.cs` `` — a file reference; must be a key
  in the symbols index. On .NET repos a member reference is `` `Type.Member` ``
  (every member has its type as `parent`), and `` `Folder/File.cs:Member` ``
  pins the file.

A span that names nothing stays plain text with no warning — so a backticked
word that is NOT meant as a reference (a CSS class, a localStorage key, a
table name) is harmless. A span that LOOKS like a file or identifier and does
not resolve is a warning and marks the chapter stale, and the workflow refuses
to commit stale chapters. Prefer fewer, correct references over many.

## Chapter order

The book is read top-down, following execution, not bottom-up by dependency:

1. Chapter 1 is always how the app starts — the entry point and what it builds
   first. Readers are most lost here and every other chapter hangs off it.
2. Then the main flows in the order a user meets them, which is the order
   `codetour.json`'s sections already give. Keep that order unless the import
   graph contradicts it: a chapter should not depend on a later chapter for
   its vocabulary, except through an `ahead` note.
3. Shared utilities and anything with high fan-in (many importers, few
   imports) come last — readers need to know they exist, not understand them
   before the app.
4. 8–12 chapters. Below 8 the areas are being crushed together; above 12 the
   read stops being one sitting.

Use `modules[].imports` to check: for each chapter, list the files its `files`
import; if most of them belong to a chapter that comes later, either move the
chapter or add an `ahead` note naming the later chapter and the one thing the
reader needs to accept for now.

## Writing a chapter

Audience: a competent developer who has never opened this repo. Voice: second
person is fine ("when you type a title…"), present tense, concrete. Each
paragraph makes one point and is grounded in a file in `files`:

- Open with what the chapter's area is for and which file is its front door.
- Describe the main flow end to end — who calls whom — naming the functions
  that carry it as references. Say what a function is responsible for, not
  what its lines do; the tour and the code viewer do the line level.
- Name the seams: where this area hands off to another (that is where an
  `ahead` note or a back-reference to an earlier chapter goes).
- Point out the one or two non-obvious rules a newcomer would get wrong
  (ownership of mutations, what never writes to the server, what runs once).
- Close with which tours go deeper, if any — one sentence, naming them.

Do not: list files, restate a tour step by step, describe CSS, invent behaviour
the code does not show, mention AI, agents, Claude, or that the book was
generated, or use placeholder text of any kind — `codebook.json` is real prose
by design (see CLAUDE.md, "Placeholder text").

## Scope

- `stale` (default): run the generator into `/tmp/book-in` and read
  `/tmp/book-in/src-book.json`. Rewrite ONLY chapters whose `stale` is `true`,
  fixing exactly what their `warnings` name (a renamed symbol, a moved file, a
  dropped tour) and re-reading that code so the prose is still true. Every
  other chapter must come out byte-for-byte identical — do not touch its text,
  its order, or its id. If nothing is stale, change nothing and say so.
  If there is no `codebook.json` at all, `stale` behaves as `all`.
- `all`: rewrite the whole book from the inputs above. Keep existing chapter
  ids where the chapter's subject is the same, so bookmarks survive.

## Validate before you finish

Run the generator into a scratch directory and read its stderr:

    MANIFEST_OUT_DIR=/tmp/book-out MANIFEST_DETERMINISTIC=true node scripts/$MANIFEST_VARIANT 2>/tmp/book-out.err
    grep 'Warning: codebook.json' /tmp/book-out.err

Every warning names a chapter and the reference, file, tour or `ahead` that
failed. Fix the prose or the reference and run again until there are no
codebook warnings and the `src-book.json written` line reports `0 stale`. If
`tests/genSrcManifest.test.js` exists and `node_modules` is installed, also run
`npx vitest run tests/genSrcManifest.test.js` and make it pass — it asserts the
committed book's order, sizes and resolution. Never edit the generator or the
tests to make the book pass.

Leave `codebook.json` as the only changed file in the working tree. Delete
nothing; write nothing under `/tmp` into the repo.

## Summary

End with one paragraph: the scope you ran, how many chapters you wrote or
rewrote and how many you left untouched, the chapter order as a list of
titles, the reference count and stale count from the generator's final run,
and anything you could not describe accurately because the code was ambiguous
(so Robert can fix the source or the map rather than the book).
