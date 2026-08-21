# scripts/lib/routine-compare.sh — the one comparison of a repo's .claude/
# routine file against the template's canonical copy. Sourced (never run) by:
#
#   onboard.sh                       preflight's `stale[]` in the report
#   scripts/check-routine-drift.sh   the CLI face of the same check
#
# It lives in one place so those two can never disagree about what "stale"
# means. Every function here is pure with respect to the repo: it reads files,
# writes only to paths it is handed, and touches no network unless asked to
# via rc_canon_path's fetch fallback.
#
# The two tiers of routine file, and why they're compared differently:
#
#   verbatim   routine-base.md — the universal routine. onboard.sh copies it in
#              with NO {{...}} substitution, so a repo's copy must be
#              byte-identical to the template's.
#
#   templated  triage.md, derive.md, project-derive.md — carry {{SRC_DIR}} and
#              {{TEST_DIR}}, resolved per repo at onboard time. A raw diff would
#              flag every repo as drifted on those lines alone, so instead the
#              repo's OWN values are read back off its copy (the anchor line
#              `Source under \`X\`, tests under \`Y\`.` is byte-stable across all
#              three), substituted into the template, and only THEN diffed. Any
#              remaining difference is real: a stale revision, or a deliberate
#              local edit — which is fine, but should be known before a backfill
#              overwrites it.
#
# NOT checked: routine.md. Fourteen placeholders, hand-completed after onboard,
# per-repo by design. There is no canonical form for it to drift from.
#
# A third tier lives at the bottom of this file: the managed workflow YAMLs
# (.github/workflows/*), verbatim copies at arbitrary repo paths, some renamed
# at onboard time (SRC>DEST). Same canonical resolution and history walk as
# routine-base.md, generalized to any path, with no {{...}} substitution.
#
# Requires: bash 4+, sed, diff, and curl only when the fetch fallback fires.

# The checked set. RC_ALL is the report order.
RC_VERBATIM=( routine-base.md )
RC_TEMPLATED=( triage.md derive.md project-derive.md )
RC_ALL=( "${RC_VERBATIM[@]}" "${RC_TEMPLATED[@]}" )

rc_is_templated() { local f; for f in "${RC_TEMPLATED[@]}"; do [ "$f" = "$1" ] && return 0; done; return 1; }
rc_is_checked()   { local f; for f in "${RC_ALL[@]}";       do [ "$f" = "$1" ] && return 0; done; return 1; }

# sed-escape a replacement string: backslash, the | delimiter, and &.
rc_sed_escape() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }

# Read the repo's own SRC_DIR / TEST_DIR back off its copy of a templated file.
# Prints "src<TAB>test", or nothing when the anchor line isn't there — a copy so
# old or so rewritten it predates the anchor. That case is reported, never
# guessed at.
rc_infer_dirs() { # $1=repo file
  sed -nE 's/^.*Source under `([^`]*)`, tests under `([^`]*)`\..*$/\1\t\2/p' "$1" | head -1
}

# Write the expected file for a repo: template with the repo's dirs substituted.
rc_render_expected() { # $1=canon $2=src $3=test $4=out
  local s t; s="$(rc_sed_escape "$2")"; t="$(rc_sed_escape "$3")"
  sed -e "s|{{SRC_DIR}}|$s|g" -e "s|{{TEST_DIR}}|$t|g" "$1" > "$4"
}

# Resolve the canonical copy of a routine file. Prefers a local template
# checkout ($1/<name>); when that isn't present — onboard.sh run outside a
# template checkout, e.g. `curl | bash` — fetches it from $2/.claude/<name>
# into $4, a temp path the CALLER owns and removes. Prints the path to use, or
# nothing on failure. (The caller supplies the temp path because this function
# is used inside $(...) — a subshell — where any bookkeeping it did itself
# would be lost.)
rc_canon_path() { # $1=local canon dir (may not exist)  $2=RAW_BASE-style URL prefix  $3=file name  $4=temp path for a fetch
  local local_path="$1/$3"
  if [ -f "$local_path" ]; then printf '%s' "$local_path"; return 0; fi
  [ -n "${2:-}" ] && [ -n "${4:-}" ] || return 1
  if curl -fsSL "$2/.claude/$3" -o "$4" 2>/dev/null; then printf '%s' "$4"; return 0; fi
  return 1
}

# Compare one routine file. Prints exactly one line:
#
#   ok
#   ok:src:test                       templated file, up to date; dirs shown
#   stale:N:src:test                  templated file, N differing lines
#   stale:N::                         verbatim file, N differing lines
#   stale:anchor                      templated file whose anchor line is gone
#
# Optional $4 receives the diff (template < vs repo >) for callers that show it.
rc_compare_file() { # $1=file name  $2=canon path  $3=repo file path  [$4=diff-out path]
  local name="$1" canon="$2" repo="$3" out="${4:-}"
  local ref="$canon" src="" test="" expect=""
  if rc_is_templated "$name"; then
    local dirs; dirs="$(rc_infer_dirs "$repo")"
    if [ -z "$dirs" ]; then printf 'stale:anchor\n'; return 0; fi
    src="${dirs%%	*}"; test="${dirs#*	}"
    expect="$(mktemp)"
    rc_render_expected "$canon" "$src" "$test" "$expect"
    ref="$expect"
  fi
  if diff -q "$ref" "$repo" >/dev/null 2>&1; then
    if [ -n "$src" ]; then printf 'ok:%s:%s\n' "$src" "$test"; else printf 'ok\n'; fi
  else
    local n; n="$(diff "$ref" "$repo" | grep -cE '^[<>]' || true)"
    [ -n "$out" ] && { diff "$ref" "$repo" > "$out" || true; }
    printf 'stale:%s:%s:%s\n' "$n" "$src" "$test"
  fi
  [ -n "$expect" ] && rm -f "$expect"
  return 0
}

# ── Local-edit detection and backfill ─────────────────────────────────────────
#
# A stale routine file is safe to overwrite only if nobody ever edited it in the
# repo — if it is simply an OLDER TEMPLATE REVISION. That is checkable: walk the
# template's git history for the file, substitute the repo's own dirs into each
# revision, and compare. A byte match proves the repo's copy is that revision
# and nothing else; overwriting it loses nothing. No match means the copy carries
# local edits (or predates recorded history), and a backfill must leave it alone.
#
# Prints one of:
#   no:<sha>    no local edits — the repo's copy IS template revision <sha>
#   yes         history walked, nothing matches — local edits exist
#   unknown     no walkable history (template not a checkout, or shallow)
rc_local_edits() { # $1=file name  $2=repo file  $3=template git dir ("" if none)  $4=src  $5=test
  local name="$1" repo="$2" gitdir="$3" src="$4" test="$5"
  { [ -n "$gitdir" ] && git -C "$gitdir" rev-parse --is-inside-work-tree >/dev/null 2>&1; } || { printf 'unknown\n'; return 0; }
  # A shallow clone holds its tip only; a walk over that proves nothing.
  if [ "$(git -C "$gitdir" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then printf 'unknown\n'; return 0; fi
  local shas; shas="$(git -C "$gitdir" log --format=%H -- ".claude/$name" 2>/dev/null || true)"
  [ -n "$shas" ] || { printf 'unknown\n'; return 0; }
  local s t cand sha; s="$(rc_sed_escape "$src")"; t="$(rc_sed_escape "$test")"; cand="$(mktemp)"
  for sha in $shas; do
    if git -C "$gitdir" show "$sha:.claude/$name" 2>/dev/null \
         | sed -e "s|{{SRC_DIR}}|$s|g" -e "s|{{TEST_DIR}}|$t|g" > "$cand" \
       && diff -q "$cand" "$repo" >/dev/null 2>&1; then
      rm -f "$cand"; printf 'no:%s\n' "$sha"; return 0
    fi
  done
  rm -f "$cand"; printf 'yes\n'; return 0
}

# Refresh one routine file in place IF it is stale and provably free of local
# edits. Writes the current template with the file's OWN inferred dirs (never
# freshly detected ones), so a backfill changes template content and nothing
# else, and the file carries no placeholders for a later subst pass to touch.
#
# Prints one of:
#   refreshed:N:src:test     overwritten; N lines changed
#   current                  already up to date, nothing to do
#   skip:anchor              anchor line missing — dirs can't be inferred
#   skip:local:N             N lines behind but has local edits — left alone
#   skip:unknown:N           N lines behind, edits unknown (no history) — left alone
rc_backfill_file() { # $1=file name  $2=canon path  $3=repo file  $4=template git dir
  local name="$1" canon="$2" repo="$3" gitdir="$4"
  local res; res="$(rc_compare_file "$name" "$canon" "$repo")"
  case "$res" in
    ok|ok:*)       printf 'current\n'; return 0 ;;
    stale:anchor)  printf 'skip:anchor\n'; return 0 ;;
  esac
  local n src test; IFS=: read -r _ n src test <<< "$res"
  local le; le="$(rc_local_edits "$name" "$repo" "$gitdir" "$src" "$test")"
  case "$le" in
    no:*)
      if rc_is_templated "$name"; then rc_render_expected "$canon" "$src" "$test" "$repo"; else cp "$canon" "$repo"; fi
      printf 'refreshed:%s:%s:%s\n' "$n" "$src" "$test" ;;
    yes)   printf 'skip:local:%s\n' "$n" ;;
    *)     printf 'skip:unknown:%s\n' "$n" ;;
  esac
  return 0
}

# ── Workflow tier ─────────────────────────────────────────────────────────────
#
# The generalized treatment for the managed .github/workflows/*.yml files,
# whose canonical copies live at the template ROOT (not .claude/) and whose
# history is walked at the SRC path — which matters for the SRC>DEST renames:
# a repo's test.yml is proven unedited by matching revisions of
# test-dotnet.yml (or whichever SRC installed it).
#
# Some of these are TEMPLATED like triage.md — test.yml, deploy.yml, and
# friends carry {{WORKING_DIR}}/{{INSTALL_COMMAND}}-style placeholders filled
# at onboard time — so both functions below take optional NAME=VALUE pairs and
# render every template revision (and the canonical) with them before any
# byte-compare. With no pairs, rendering is the identity and this is the plain
# verbatim walk. The pairs come from onboard.sh's wf_backfill_pairs, the early
# mirror of its section-4b substitution rules.

# Render {{KEY}} -> value pairs from $3.. into a copy of $1 at $2. Zero pairs
# (or a file with no placeholders) makes this a plain copy. Same sed idiom as
# onboard.sh's subst().
rc_render_pairs() { # $1=in file  $2=out file  [$3..]=NAME=VALUE pairs
  local out="$2"
  cp "$1" "$out"
  shift 2
  local pair k v esc
  for pair in "$@"; do
    k="${pair%%=*}"; v="${pair#*=}"
    esc="$(rc_sed_escape "$v")"
    sed -i.bak "s|{{$k}}|$esc|g" "$out" && rm -f "$out.bak"
  done
  return 0
}

# Strip a TEMPLATE INSTANTIATION NOTES block — the comment run from an opening
# "# ──…" rule line whose NEXT line is "# TEMPLATE INSTANTIATION NOTES",
# through the closing "# ──…" rule — before comparing. The notes are
# instructions to a HUMAN instantiating by hand: machine-onboarded copies keep
# them and hand-built originals (the template's own ancestors) never had them,
# so counting them as drift made the origin repo read 90 lines stale over 3
# real differences. COMPARE-ONLY: refreshes still write the canonical verbatim,
# notes included.
rc_strip_notes() { # $1=in file  $2=out file
  awk '
    { if (inblk) { if ($0 ~ /^# ──/) inblk=0; next }
      if (pend != "") {
        if ($0 ~ /^# TEMPLATE INSTANTIATION NOTES/) { inblk=1; pend=""; next }
        print pend; pend=""
      }
      if ($0 ~ /^# ──/) { pend=$0; next }
      print }
    END { if (pend != "") print pend }
  ' "$1" > "$2"
  return 0
}

# Notes-blind compare of two files. Prints the count of differing lines after
# rc_strip_notes on both sides; 0 means effectively identical.
rc_stripped_diff() { # $1=file A  $2=file B
  local a b n; a="$(mktemp)"; b="$(mktemp)"
  rc_strip_notes "$1" "$a"
  rc_strip_notes "$2" "$b"
  n="$(diff "$a" "$b" | grep -cE '^[<>]' || true)"
  rm -f "$a" "$b"
  printf '%s' "$n"
  return 0
}

# Resolve the canonical copy of ANY template file by its SRC-relative path.
# Same contract as rc_canon_path (caller owns $4), without the .claude/ prefix.
rc_canon_path_any() { # $1=template checkout root (may be "")  $2=RAW_BASE-style URL prefix  $3=SRC rel path  $4=temp path for a fetch
  if [ -n "${1:-}" ] && [ -f "$1/$3" ]; then printf '%s' "$1/$3"; return 0; fi
  [ -n "${2:-}" ] && [ -n "${4:-}" ] || return 1
  if curl -fsSL "$2/$3" -o "$4" 2>/dev/null; then printf '%s' "$4"; return 0; fi
  return 1
}

# rc_local_edits for a file at an arbitrary SRC path: walk the template's
# history for SRC, render each revision with the given pairs, and byte-compare
# to the repo's copy. Same output vocabulary (no:<sha> / yes / unknown), same
# shallow-clone guard.
rc_local_edits_path() { # $1=SRC rel path  $2=repo file  $3=template git dir ("" if none)  [$4..]=NAME=VALUE pairs
  local src="$1" repo="$2" gitdir="$3"
  shift 3
  { [ -n "$gitdir" ] && git -C "$gitdir" rev-parse --is-inside-work-tree >/dev/null 2>&1; } || { printf 'unknown\n'; return 0; }
  if [ "$(git -C "$gitdir" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then printf 'unknown\n'; return 0; fi
  local shas; shas="$(git -C "$gitdir" log --format=%H -- "$src" 2>/dev/null || true)"
  [ -n "$shas" ] || { printf 'unknown\n'; return 0; }
  local raw cand rstrip cstrip sha
  raw="$(mktemp)"; cand="$(mktemp)"; rstrip="$(mktemp)"; cstrip="$(mktemp)"
  rc_strip_notes "$repo" "$rstrip"
  for sha in $shas; do
    if git -C "$gitdir" show "$sha:$src" > "$raw" 2>/dev/null; then
      rc_render_pairs "$raw" "$cand" "$@"
      rc_strip_notes "$cand" "$cstrip"
      if diff -q "$cstrip" "$rstrip" >/dev/null 2>&1; then
        rm -f "$raw" "$cand" "$rstrip" "$cstrip"; printf 'no:%s\n' "$sha"; return 0
      fi
    fi
  done
  rm -f "$raw" "$cand" "$rstrip" "$cstrip"; printf 'yes\n'; return 0
}

# rc_backfill_file for a file at an arbitrary SRC path. Compares against — and
# on refresh, writes — the canonical RENDERED with the given pairs, so a
# templated workflow never lands in a repo with literal {{...}} in it. Same
# output vocabulary; no anchor case (values come from the caller, not the file).
rc_backfill_path() { # $1=SRC rel path  $2=canon path  $3=repo file  $4=template git dir  [$5..]=NAME=VALUE pairs
  local src="$1" canon="$2" repo="$3" gitdir="$4"
  shift 4
  local rendered; rendered="$(mktemp)"
  rc_render_pairs "$canon" "$rendered" "$@"
  # Notes-blind: see rc_strip_notes. The write below still uses the rendered
  # canonical verbatim; only the compare and the count ignore the notes.
  local n; n="$(rc_stripped_diff "$rendered" "$repo")"
  if [ "$n" = "0" ]; then rm -f "$rendered"; printf 'current\n'; return 0; fi
  local le; le="$(rc_local_edits_path "$src" "$repo" "$gitdir" "$@")"
  case "$le" in
    no:*) cp "$rendered" "$repo"; rm -f "$rendered"; printf 'refreshed:%s::\n' "$n" ;;
    yes)  rm -f "$rendered"; printf 'skip:local:%s\n' "$n" ;;
    *)    rm -f "$rendered"; printf 'skip:unknown:%s\n' "$n" ;;
  esac
  return 0
}
