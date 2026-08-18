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
#         GH_TOKEN        a GitHub token; needed to read PRIVATE repos. Without
#                         it, raw GitHub returns 404 for every file in a private
#                         repo — indistinguishable from the file being absent —
#                         so this script reports such a repo as "MISSING (or
#                         private — set GH_TOKEN)". `gh auth token` yields one.
#                         Beware: an INVALID or expired token makes raw GitHub
#                         404 on PUBLIC repos too — so if every repo suddenly
#                         reads unreadable, suspect the token before the repos.
# Exit:   0 if every checked file in every repo is up to date;
#         1 if any drift / missing / error;
#         2 on a usage/setup problem.
#
# The comparison itself lives in scripts/lib/routine-compare.sh, shared with
# onboard.sh's preflight (which reports the same thing as `stale[]`), so the two
# can never disagree.
#
# Requires: bash 4+, curl, diff, sed, python3 (only for the worker-list path).

set -uo pipefail

BRANCH="${ROUTINE_BRANCH:-main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANON_DIR="$SCRIPT_DIR/../.claude"
SHOW_DIFF=0

# The two tiers, and every comparison helper, come from the shared lib.
. "$SCRIPT_DIR/lib/routine-compare.sh" || { echo "scripts/lib/routine-compare.sh not found beside this script" >&2; exit 2; }
VERBATIM_FILES=( "${RC_VERBATIM[@]}" )
TEMPLATED_FILES=( "${RC_TEMPLATED[@]}" )
ALL_FILES=( "${RC_ALL[@]}" )

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
tmp="$(mktemp)"; dtmp="$(mktemp)"; trap 'rm -f "$tmp" "$dtmp"' EXIT

# Fetch a repo file into $tmp; echo the HTTP code.
# GH_TOKEN, when set, is sent as `Authorization: token …` — raw.githubusercontent
# honours it for private repos. Public repos work either way, so setting it is
# always safe; NOT setting it silently turns every private repo into a wall of
# 404s (see the header). The token never appears in output.
GH_AUTH=()
[ -n "${GH_TOKEN:-}" ] && GH_AUTH=( -H "Authorization: token ${GH_TOKEN}" )
fetch() { # $1=repo $2=relpath
  # Cache-buster: raw's CDN caches ~5min by path; a unique query nudges a fresh
  # read where honored (harmless where ignored). A backfill can still take a few
  # minutes to reflect here.
  local url="https://raw.githubusercontent.com/${1}/${BRANCH}/${2}?_=$(date +%s%N)"
  curl -sS "${GH_AUTH[@]+"${GH_AUTH[@]}"}" -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null || echo 000
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
  # Neither derive file AND no routine-base.md: raw is 404ing on everything,
  # which is not a repo that lost its whole .claude/ — it is a repo raw cannot
  # serve to us. Without a token that means private; with one it means the
  # token can't read this repo or is invalid/expired (an invalid token 404s
  # even public repos). Say the right one once and move on — four MISSING rows
  # would point at the wrong problem.
  if [ "$has_derive" = 0 ] && [ "$has_pderive" = 0 ]; then
    code="$(fetch "$repo" ".claude/routine-base.md")"
    if [ "$code" = "404" ]; then
      if [ -z "${GH_TOKEN:-}" ]; then
        printf '%-45s %-20s %s\n' "$repo" "(all)" "UNREADABLE — 404 on every file; private repo? set GH_TOKEN and re-run"
      else
        printf '%-45s %-20s %s\n' "$repo" "(all)" "UNREADABLE — 404 on every file even with GH_TOKEN; token lacks access to this repo, or is invalid/expired"
      fi
      missing["$repo"]+="(unreadable) "; checked=$((checked + ${#ALL_FILES[@]}))
      continue
    fi
  fi

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
    res="$(rc_compare_file "$f" "$canon" "$tmp" "$dtmp")"
    case "$res" in
      ok)
        printf '%-45s %-20s %s\n' "$repo" "$f" "up to date"; ok=$((ok + 1)) ;;
      ok:*)
        IFS=: read -r _ src test <<< "$res"
        printf '%-45s %-20s %s\n' "$repo" "$f" "up to date  [src=$src test=$test]"; ok=$((ok + 1)) ;;
      stale:anchor)
        printf '%-45s %-20s %s\n' "$repo" "$f" "STALE   (anchor line missing — predates the current template)"
        stale["$repo"]+="$f " ;;
      stale:*)
        IFS=: read -r _ n src test <<< "$res"
        note=""; [ -n "$src" ] && note="  [src=$src test=$test]"
        # Can the file be refreshed losslessly? Only if it IS an older template
        # revision — see rc_local_edits. The template checkout beside this
        # script is the history that gets walked.
        case "$(rc_local_edits "$f" "$tmp" "$SCRIPT_DIR/.." "$src" "$test")" in
          no:*)   note="$note  no local edits — refresh is lossless" ;;
          yes)    note="$note  HAS LOCAL EDITS — refresh by hand" ;;
          *)      note="$note  local edits unknown (shallow checkout?)" ;;
        esac
        printf '%-45s %-20s %s\n' "$repo" "$f" "STALE   (${n} differing lines)${note}"
        stale["$repo"]+="$f "
        if [ "$SHOW_DIFF" = "1" ]; then
          echo "----- diff: template (<) vs ${repo}/.claude/${f} (>) -----"
          cat "$dtmp"
          echo "-----------------------------------------------------------"
        fi ;;
    esac
  done
done

# ---- summary --------------------------------------------------------------
echo
echo "checked ${checked} files across ${#repos[@]} repos: ${ok} up to date, ${#stale[@]} repos with stale files, ${#missing[@]} with missing, ${#errored[@]} with errors"
if [ "${#stale[@]}" -gt 0 ]; then
  echo
  echo "backfill the stale files. Files marked 'no local edits' can be refreshed losslessly:"
  echo "run Onboard on the repo with 'refresh stale routine files' on (onboard.yml's"
  echo "backfill_stale input), or copy the template's and substitute this repo's own"
  echo "SRC_DIR / TEST_DIR (shown in brackets). Files marked HAS LOCAL EDITS need a hand"
  echo "merge — --show-diff shows exactly what's local."
  for r in "${!stale[@]}"; do echo "  - $r: ${stale[$r]}"; done | sort
  echo "(re-run with --show-diff to see exactly what differs.)"
fi

for r in "${!missing[@]}"; do
  case "${missing[$r]}" in *unreadable*)
    echo
    if [ -z "${GH_TOKEN:-}" ]; then
      echo "one or more repos returned 404 on every file. If they are private, export GH_TOKEN"
      echo "(e.g. GH_TOKEN=\$(gh auth token)) and re-run — raw GitHub needs it to serve them."
    else
      echo "one or more repos returned 404 on every file WITH a token set. Either the token can't"
      echo "read them (scope: repo, not public_repo; fine-grained: include the repo) or it is"
      echo "invalid/expired — an invalid token 404s even public repos, so if EVERY repo reads"
      echo "unreadable, the token is the problem."
    fi
    break ;;
  esac
done

# non-zero exit if anything needs attention (usable as a CI / pre-push gate)
[ "${#stale[@]}" -eq 0 ] && [ "${#missing[@]}" -eq 0 ] && [ "${#errored[@]}" -eq 0 ]