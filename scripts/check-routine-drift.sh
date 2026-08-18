#!/usr/bin/env bash
# check-routine-drift.sh — audit whether each onboarded repo's .claude/ routine
# files match THIS template's canonical copies.
#
# onboard.sh copies the routine files into a repo once, at onboard time, and
# never touches them again. So every later edit to the template leaves the
# fleet stale until someone backfills — and nothing else tells you which repos
# are behind. This script fetches each repo's copies from raw GitHub and diffs
# them against the local canonical ones.
#
# Two tiers of file, checked differently:
#
#   verbatim   routine-base.md — the universal routine. onboard.sh copies it in
#              with NO {{...}} substitution, so a repo's copy must be
#              byte-identical to the template's.
#
#   templated  triage.md, derive.md, project-derive.md — carry {{SRC_DIR}} and
#              {{TEST_DIR}}, resolved per repo at onboard time. A raw diff would
#              flag every repo as drifted on those lines alone, so instead the
#              repo's OWN values are read back off its copy (the line
#              `Source under \`X\`, tests under \`Y\`.` is in every one of them),
#              substituted into the template, and only THEN diffed. Any
#              remaining difference is real drift: a stale template revision,
#              or a deliberate local edit (which is fine — but you should know
#              it's there before you overwrite it with a backfill).
#
# NOT checked: routine.md. It carries fourteen placeholders and is meant to be
# hand-completed after onboard, so it is per-repo by design and has no
# canonical form to drift from.
#
# A repo carries derive.md OR project-derive.md, never both (purpose=assignment
# vs purpose=project). The absent one is reported as "n/a", not "missing".
#
# IMPORTANT: run this from a checkout of THIS template whose .claude/ is already
# up to date — the local copies are the reference everything is diffed against.
# If your template checkout is stale, every repo will falsely read as current.
#
# Repo list, in priority order:
#   1. CLI args:   scripts/check-routine-drift.sh owner/repoA owner/repoB
#   2. The Worker: export TODO_INJECTOR_URL and TODO_INJECTOR_SECRET, and the
#      fleet is pulled from the worker's `repos` route (ALLOWED_TARGETS — the
#      single source of truth for which repos are wired in).
#
# Flags:  --show-diff   print the actual diff for each stale file.
#         --only FILE   check just one file (e.g. --only derive.md). Repeatable.
# Env:    ROUTINE_BRANCH  branch to read from (default: main).
# Exit:   0 if every checked file in every repo is up to date;
#         1 if any drift / missing / error;
#         2 on a usage/setup problem.
#
# Requires: bash 4+, curl, diff, sed, python3 (only for the worker-list path).

set -uo pipefail

BRANCH="${ROUTINE_BRANCH:-main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANON_DIR="$SCRIPT_DIR/../.claude"
SHOW_DIFF=0

# The two tiers. Order here is the report order.
VERBATIM_FILES=( routine-base.md )
TEMPLATED_FILES=( triage.md derive.md project-derive.md )
ALL_FILES=( "${VERBATIM_FILES[@]}" "${TEMPLATED_FILES[@]}" )

ARGS=(); ONLY=()
while [ $# -gt 0 ]; do
  case "$1" in
    --show-diff) SHOW_DIFF=1 ;;
    --only) shift; [ $# -gt 0 ] || { echo "--only needs a filename" >&2; exit 2; }; ONLY+=("$1") ;;
    -h|--help) sed -n '2,54p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

# Narrow the file set if --only was given; validate the names.
if [ "${#ONLY[@]}" -gt 0 ]; then
  narrowed=()
  for want in "${ONLY[@]}"; do
    hit=0
    for f in "${ALL_FILES[@]}"; do [ "$f" = "$want" ] && { narrowed+=("$f"); hit=1; }; done
    [ "$hit" = 1 ] || { echo "--only $want: not a checked file (choose from: ${ALL_FILES[*]})" >&2; exit 2; }
  done
  ALL_FILES=( "${narrowed[@]}" )
fi

for f in "${ALL_FILES[@]}"; do
  [ -f "$CANON_DIR/$f" ] || { echo "canonical copy not found at $CANON_DIR/$f — run from the template checkout" >&2; exit 2; }
done

is_templated() { local f; for f in "${TEMPLATED_FILES[@]}"; do [ "$f" = "$1" ] && return 0; done; return 1; }

# ---- resolve the repo list ------------------------------------------------
repos=()
if [ "${#ARGS[@]}" -gt 0 ]; then
  repos=("${ARGS[@]}")
elif [ -n "${TODO_INJECTOR_URL:-}" ] && [ -n "${TODO_INJECTOR_SECRET:-}" ]; then
  resp="$(curl -fsS -X POST "$TODO_INJECTOR_URL" \
    -H "Authorization: Bearer $TODO_INJECTOR_SECRET" \
    -H "Content-Type: application/json" \
    -d '{"repos":true}' 2>/dev/null)" || { echo "worker 'repos' request failed (check URL/secret)" >&2; exit 2; }
  mapfile -t repos < <(printf '%s' "$resp" | python3 -c \
    'import sys,json; [print(r["repo"]) for r in json.load(sys.stdin).get("repos",[])]' 2>/dev/null)
  [ "${#repos[@]}" -gt 0 ] || { echo "worker returned no repos" >&2; exit 2; }
else
  cat >&2 <<EOF
No repos to check. Either:
  pass them as args:   $0 owner/repoA owner/repoB
  or set the worker:   TODO_INJECTOR_URL=... TODO_INJECTOR_SECRET=... $0
EOF
  exit 2
fi

# ---- helpers --------------------------------------------------------------
tmp="$(mktemp)"; expect="$(mktemp)"; trap 'rm -f "$tmp" "$expect"' EXIT

# Fetch a repo file into $tmp; echo the HTTP code.
fetch() { # $1=repo $2=relpath
  # Cache-buster: raw's CDN caches ~5min by path; a unique query nudges a fresh
  # read where honored (harmless where ignored). A backfill can still take a few
  # minutes to reflect here.
  local url="https://raw.githubusercontent.com/${1}/${BRANCH}/${2}?_=$(date +%s%N)"
  curl -sS -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null || echo 000
}

# Read the repo's own SRC_DIR / TEST_DIR back off its copy of a templated file.
# The anchor line onboard.sh substitutes into is byte-stable across the three
# templated files:   Source under `{{SRC_DIR}}`, tests under `{{TEST_DIR}}`.
# Prints "src<TAB>test" or nothing if the line isn't found (a copy so old or so
# rewritten it predates the anchor — reported as unresolvable rather than
# guessed at).
infer_dirs() { # $1=file
  sed -nE 's/^.*Source under `([^`]*)`, tests under `([^`]*)`\..*$/\1\t\2/p' "$1" | head -1
}

sed_escape() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }

# Build the expected file for a repo: template with the repo's dirs substituted.
render_expected() { # $1=canon $2=src $3=test  -> writes $expect
  local s t; s="$(sed_escape "$2")"; t="$(sed_escape "$3")"
  sed -e "s|{{SRC_DIR}}|$s|g" -e "s|{{TEST_DIR}}|$t|g" "$1" > "$expect"
}

# ---- audit ----------------------------------------------------------------
declare -A stale=() missing=() errored=()
ok=0; checked=0

col=$(( 45 ))
printf '%-45s %-20s %s\n' "REPO" "FILE" "STATUS"
printf '%-45s %-20s %s\n' "----" "----" "------"

for repo in "${repos[@]}"; do
  # Purpose detection: which derive file this repo carries. Probe both up front
  # so the absent one can be reported as n/a instead of missing.
  has_derive=0; has_pderive=0
  code="$(fetch "$repo" ".claude/derive.md")";         [ "$code" = 200 ] && has_derive=1
  code="$(fetch "$repo" ".claude/project-derive.md")"; [ "$code" = 200 ] && has_pderive=1

  for f in "${ALL_FILES[@]}"; do
    # Skip the derive variant this repo doesn't carry.
    if [ "$f" = "derive.md" ] && [ "$has_derive" = 0 ] && [ "$has_pderive" = 1 ]; then
      printf '%-45s %-20s %s\n' "$repo" "$f" "n/a (project repo)"; continue
    fi
    if [ "$f" = "project-derive.md" ] && [ "$has_pderive" = 0 ] && [ "$has_derive" = 1 ]; then
      printf '%-45s %-20s %s\n' "$repo" "$f" "n/a (assignment repo)"; continue
    fi

    checked=$((checked + 1))
    code="$(fetch "$repo" ".claude/$f")"
    if [ "$code" = "404" ]; then
      printf '%-45s %-20s %s\n' "$repo" "$f" "MISSING (not on ${BRANCH})"
      missing["$repo"]+="$f "; continue
    elif [ "$code" != "200" ]; then
      printf '%-45s %-20s %s\n' "$repo" "$f" "ERROR   (HTTP ${code})"
      errored["$repo"]+="$f "; continue
    fi

    canon="$CANON_DIR/$f"
    if is_templated "$f"; then
      dirs="$(infer_dirs "$tmp")"
      if [ -z "$dirs" ]; then
        printf '%-45s %-20s %s\n' "$repo" "$f" "STALE   (anchor line missing — predates the current template)"
        stale["$repo"]+="$f "; continue
      fi
      src="${dirs%%	*}"; test="${dirs#*	}"
      render_expected "$canon" "$src" "$test"
      ref="$expect"; note="  [src=$src test=$test]"
    else
      ref="$canon"; note=""
    fi

    if diff -q "$ref" "$tmp" >/dev/null 2>&1; then
      printf '%-45s %-20s %s\n' "$repo" "$f" "up to date${note}"
      ok=$((ok + 1))
    else
      d="$(diff "$ref" "$tmp" | grep -cE '^[<>]' || true)"
      printf '%-45s %-20s %s\n' "$repo" "$f" "STALE   (${d} differing lines)${note}"
      stale["$repo"]+="$f "
      if [ "$SHOW_DIFF" = "1" ]; then
        echo "----- diff: template (<) vs ${repo}/.claude/${f} (>) -----"
        diff "$ref" "$tmp" || true
        echo "-----------------------------------------------------------"
      fi
    fi
  done
done

# ---- summary --------------------------------------------------------------
echo
echo "checked ${checked} files across ${#repos[@]} repos: ${ok} up to date, ${#stale[@]} repos with stale files, ${#missing[@]} with missing, ${#errored[@]} with errors"
if [ "${#stale[@]}" -gt 0 ]; then
  echo
  echo "backfill the stale files. For routine-base.md, copy the template's verbatim."
  echo "For the templated files, copy the template's and substitute this repo's own"
  echo "SRC_DIR / TEST_DIR (shown in brackets above) — or re-run onboard.sh's subst on it."
  echo "A repo with a DELIBERATE local edit will read as stale too; check --show-diff"
  echo "before overwriting one."
  for r in "${!stale[@]}"; do echo "  - $r: ${stale[$r]}"; done | sort
  echo "(re-run with --show-diff to see exactly what differs.)"
fi

# non-zero exit if anything needs attention (usable as a CI / pre-push gate)
[ "${#stale[@]}" -eq 0 ] && [ "${#missing[@]}" -eq 0 ] && [ "${#errored[@]}" -eq 0 ]
