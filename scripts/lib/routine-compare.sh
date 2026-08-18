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
