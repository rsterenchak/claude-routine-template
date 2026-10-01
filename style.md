# Code style — how code in this repo should be written

This file describes HOW code is written here: naming, structure, and the shape of
a class or module. It is separate from `CLAUDE.md` (what the repo IS — its file
map and architecture) and from `.claude/routine.md` (how the pipeline behaves),
because style changes on a different cadence than either and belongs in a file
the routine reads before it writes code.

Comment style lives in its own file, `commenting-style.md`, and is not repeated
here. Read both.

These conventions are drawn from code the repo owner wrote by hand. The point is
that generated code reads like the rest of the codebase — same naming, same
structure, same idioms — not that it reads like anyone's idea of ideal code.

<correctness_is_not_style>
Everything below describes STRUCTURE and NAMING. None of it licenses a defect.

Whatever a task's style mode, the following always hold:

- Code compiles, runs, and passes the project's test suite.
- No known-broken idiom is reproduced because it appears in an example. In
  particular, and by name: do NOT use a randomly-generated value as a React
  `key` (it changes across renders and defeats reconciliation); do NOT put an
  expression in a `useEffect` dependency array (`[flag === false]` evaluates to
  a boolean and does not do what it looks like); do NOT leave commented-out
  blocks of dead code in a shipped file.
- Names are accurate. A variable called `activeShuffledArray` holds a shuffled
  array; if the value changes meaning, the name changes with it.
- Nothing is left half-done and unmarked. If a piece cannot be finished, say so
  in the PR body rather than shipping a stub that reads as complete.

If a style rule here ever appears to require an incorrect implementation, the
style rule loses. Report the conflict in the PR body.
</correctness_is_not_style>

<naming>
Applies to every language in this repo.

- Booleans and boolean-ish state read as a question: prefix `is` (`isSide`,
  `isOver`, `isHovered`, `isInitialTurn`).
- State holding the current live value of something prefixes `active`
  (`activeScore`, `activePickedArray`, `activeTopRow`, `activeCurrentAudio`).
  The prefix distinguishes "the value in play right now" from a constant or a
  derived local.
- Setters and handlers prefix `set` (`setPickedArray`, `setHomePage`,
  `setupPage`). A function whose whole job is to cause a state change reads as
  `set…`, whether or not it is a React setter.
- Event handlers prefix `handle` (`handleMusicClick`, `handleOutsideClick`,
  `handleEscape`).
- Refs suffix `Ref` (`musicWrapperRef`, `longPressTimerRef`).
- Loop counters are named `counter`, not `i`, when the loop body is more than a
  couple of lines. `i` is fine in a one-line map or a tight index loop.
- Names are spelled out rather than abbreviated: `randomArrayPositions`, not
  `randPos`. Length is not a cost; guessing what a name meant is.
</naming>

<javascript_and_react>
- Components live one per file, PascalCase filename matching the export
  (`Card.jsx`, `MobileMenu.jsx`, `PlayPage.jsx`). Default export.
- Styling is a shared `style.css` imported at the top, with semantic class names
  (`scorePanelRow`, `instructionsBackdrop`, `navStackButton`). Inline `style`
  objects are for values computed at runtime (a background image, a conditional
  blur, a cursor that depends on state) — defined as a named object above the
  return (`boxStyle`, `popUpStyle`) rather than inlined in JSX.
- Prefer `function name() {}` declarations over `const name = () => {}` for
  anything with a body. Arrow functions are for inline callbacks and one-liners.
- Algorithmic work uses an explicit `while` loop with a `counter`, not
  `for`/`reduce`/chained array methods. Rendering a list uses `.map()`. The split
  is deliberate: `.map()` where the shape is "one element per item", `while`
  where the loop is doing real work with conditions and accumulation.
- Effects are declared with their dependency array, cleanup returned from the
  effect body. A listener added in an effect is removed in its cleanup, always.
- Guard clauses at the top of an effect (`if (!sliderOpen) return;`) rather than
  wrapping the whole body in a conditional.
</javascript_and_react>

<java>
- Every class opens with a block comment stating what the class is responsible
  for, followed by tags in this order and format:

      /*
       * <One or two sentences on what this class is responsible for.>
       *
       * @author     Robert Sterenchak
       * @assignment <course code> Assignment: <assignment name>
       * @date       <Month DD, YYYY>
       */

  The author is always Robert Sterenchak. The date is the date the file is
  written. Do NOT carry an instructor or template author through into generated
  files.
- Members are grouped under section comments in this order, each introduced by a
  Javadoc-style marker:

      //instance variables
      /** Constructors */
      /** Accessor Methods */
      /** Mutator Methods */
      /** toString Method */
      /** compareTo Method */

  Sections that do not apply are omitted; the order of those present is fixed.
- Instance variables are private and initialised explicitly at declaration, even
  where the default would be the same (`private Node next = null;`).
- Field access inside the class is always qualified with `this.`
  (`this.person`, `this.getPerson()`), including in accessors and constructors.
- Constructors delegate to setters rather than assigning fields directly, so a
  validation added to a setter later applies to construction too.
- Overloaded constructors are declared shortest-first.
- Accessors return `this.<field>`; mutators take a parameter named for what it
  is (`setPerson(Person newPerson)`), not `p` or `value`.
</java>

<csharp>
Translated from the Java conventions above; where the two differ, this section
governs C# files.

- One class per file, filename matching the class name exactly. File-scoped
  namespaces (`namespace ProjectName.Core;`).
- The file header is the one in `commenting-style.md`: a short paragraph, then
  `Robert Sterenchak` and the date. Do NOT use the Java section's
  `@author` / `@assignment` / `@date` tag block, and add no course, assignment,
  or requirement fields.
- When the assignment supplies a class diagram, every class and member it shows
  keeps the diagram's name, casing, and types exactly, even where that breaks
  C# convention. Otherwise methods are camelCase and properties PascalCase, and
  anything you add follows the same casing so the class reads as one piece.
- Members are grouped under section comments in this order, omitting any that
  do not apply:

      //instance variables
      /** Constructors */
      /** Properties */
      /** Methods */
      /** Event Handlers */

- Fields are private and initialised explicitly at declaration, even where the
  default would be the same (`private int nextID = 0;`).
- Member access inside the class is always qualified with `this.`
  (`this.Items.Add(item)`, `this.itemsGrid.DataSource = ...`).
- Constructors assign through properties rather than backing fields, so a check
  added to a setter later applies to construction too. Overloaded constructors
  are declared shortest-first.
- A diagrammed `<<prop>>` is a C# property. Use an auto-property unless the
  setter needs logic.
- Event handlers use the Visual Studio designer's default name,
  `<controlName>_<EventName>` (`saveButton_Click`,
  `itemsGrid_SelectionChanged`, `MainForm_Load`), so a handler created by
  double-clicking a control in the designer matches the ones already in the
  file. This overrides the `handle` prefix in the naming section above for C#
  files, and is the one exception to camelCase method names. Because handlers
  are named after their control, controls must be renamed to their final names
  before a handler is attached — never leave `button1_Click`.
- Controls are named in full, with their role as a suffix: `saveButton`,
  `itemsGrid`, `searchTextBox`, `activeCheckBox`, `nameLabel`. Never `button1`,
  never a `btn` / `txt` prefix.
- Lookup and search logic uses an explicit loop — `foreach`, or `while` with a
  `counter` when the index matters — not a LINQ chain. The loop is the work, so
  it stays visible.

`.Designer.cs` files follow the Visual Studio designer's own layout. The file
header from `commenting-style.md` still goes at the top, but the rest of the
commenting style does NOT apply inside `InitializeComponent` or the designer's
control-field declarations: the designer rewrites both on every save and drops
comments there. The designer's standard `#region Windows Form Designer
generated code` and its `components` / `Dispose` boilerplate stay exactly as
Visual Studio writes them. That wording is the IDE's own, not a reference to
assistant tooling.
</csharp>

<structure>
- A function does one thing named by its name. When a function grows past the
  point where its name still describes it, that is the signal to split — not a
  line count.
- Extract when there is a second caller, or when a block needs a name to be
  understood. Do NOT extract a single-use block purely to shorten the parent.
- Files are organised top to bottom in reading order: imports, constants, state
  and refs, effects, helper functions, derived values, then the return or main
  body. A reader should be able to go down the file once without jumping.
- Related helpers stay adjacent to each other and near their caller, rather than
  being alphabetised or grouped by visibility.
</structure>

<style_modes>
A task may carry a `Style:` line alongside its `Type:` line. It affects
STRUCTURE ONLY — every rule in <correctness_is_not_style> still holds, tests
still pass, and the naming and file conventions above still apply.

- `Style: naive` — write the direct, obvious implementation. Solve the problem
  the way it presents itself: an explicit loop over a clever one-liner, a
  straightforward conditional over an early-return chain, repeated code left
  repeated rather than factored out on first sight. Do not reach for a
  higher-order function, a lookup table, or an abstraction because it would be
  tidier. The purpose is a readable starting point that a later optimisation
  pass can be compared against — the diff between the two IS the artifact, and
  an already-optimal first version leaves nothing to read.
- `Style: optimise` — a pass over existing working code that improves its
  structure WITHOUT changing behavior. Factor out genuine repetition, replace a
  hand-rolled loop with the idiom that expresses it, collapse redundant casts
  and temporaries, tighten conditionals. Tests must pass unchanged; if a test
  needs editing, the change was not behavior-preserving and must be reported
  rather than absorbed.
- No `Style:` line — write it the way you normally would, following everything
  above.

An unrecognised `Style:` value is treated as absent and reported in the PR body.
Never infer a style mode from the task's title or description.
</style_modes>
