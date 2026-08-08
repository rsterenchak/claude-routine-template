# Mockups

Approved visual designs for this project's surfaces, committed so they outlive
the conversation that produced them.

A design agreed in chat and never saved is a decision the repo cannot see. A run
three weeks later has no way to check its work against it, and neither does the
derive pass reading `project.md`. Saving the file makes "matches the approved
mockup" verifiable instead of remembered.

## What goes here

**HTML or SVG, not screenshots.** A run can `Read` markup and reason about it; a
PNG is opaque. Standalone HTML with inline styles is ideal — it renders in a
browser, in the app's code viewer, and reads as text to an agent.

**One file per surface**, named for the surface: `queue-rail.html`,
`onboard-modal.html`. `project.md`'s Surfaces section references these by path,
so the names are the link between the brief and the design.

## Delete them once shipped

A mockup describing a surface that has since been rebuilt is worse than no
mockup, because a run will treat it as current and hold new work against a design
you abandoned. Keep only the ones for surfaces **not yet built**.

Read this folder as pending work, not as documentation. `CLAUDE.md` is where
settled conventions live.
