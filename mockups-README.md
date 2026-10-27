# Mockups

Approved visual designs for this project's surfaces, committed so they outlive
the conversation that produced them.

A design agreed in chat and never saved is a decision the repo cannot see. A run
three weeks later has no way to check its work against it, and neither does the
derive pass reading the brief. Saving the file makes "matches the approved
mockup" verifiable instead of remembered.

## What goes here

**Something a run can read.** Standalone HTML with inline styles is ideal when
you're free to choose — it renders in a browser, in the app's code viewer, and
reads as text to an agent. SVG works the same way.

**When the design has to be an image, consider writing the spec beside it.**
Coursework wireframes are often a graded deliverable submitted as PNGs, and that
isn't negotiable. A run and the derive pass CAN read a PNG — the Read tool renders
images — so an image on its own is a usable design and can be referenced from the
brief directly. A `README.md` in the same folder carrying what the picture shows
in prose — the regions and their DOM order, the page inventory, what belongs in
each region, which requirement each part answers — still earns its place when the
surface is more than a layout: prose states intent and ordering a wireframe only
implies, and the passes treat it as authoritative where it and the picture
differ. Reference the prose file from the brief when it exists, the image when it
doesn't.

## Entry screenshots — `docs/context/`

Separate from mockups: a TODO.md entry may carry one screenshot as context for
the run that ships it — the broken state for a bug, the region for a feature.
The app commits it at `docs/context/<entry id>.<ext>` beside TODO.md when the
entry is injected, and the entry's `- Screenshot:` line names that path. The run
opens it with the Read tool before writing code, and the commit that marks the
entry complete deletes it. Nothing here is a design decision; it is throwaway
context with the lifetime of one entry, and nothing should reference it except
the entry it belongs to.

**One file per surface**, named for the surface: `queue-rail.html`,
`onboard-modal.html`. The brief references these by path — `project.md`'s
Surfaces section on a personal repo, `assignment.md`'s Mockups section on a
coursework one — so the names are the link between the brief and the design.

On a coursework repo the reference is also a gate: derive parks a visual
requirement rather than drafting it until a design is committed here AND named
from `assignment.md`. Committing the file alone is not enough.

## Delete them once shipped — unless they're graded

A mockup describing a surface that has since been rebuilt is worse than no
mockup, because a run will treat it as current and hold new work against a design
you abandoned. Keep only the ones for surfaces **not yet built**.

**Coursework is the exception.** A layout submitted as part of an earlier task is
an artifact of the submission, and a later task may ask for it again to show what
changed. Never delete one of those. Update it when the build diverges and note
the change; that is the requirement, not a cleanup you skipped.

Outside that, read this folder as pending work rather than documentation.
`CLAUDE.md` is where settled conventions live.
