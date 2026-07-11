#!/usr/bin/env bash
# check-routine-drift.sh — audit whether each onboarded repo's
# .claude/routine-base.md matches THIS template's canonical copy.
#
# routine-base.md is the UNIVERSAL routine: onboard.sh copies it in verbatim
# (no {{...}} substitution), so every onboarded repo's copy should be
# byte-identical to the template's. This script fetches each repo's copy from
# raw GitHub and diffs it against the local canonical copy, so after you edit
# the template's routine-base.md you can see which repos need a backfill.
#
# IMPORTANT: run this from a checkout of THIS template whose routine-base.md is
# already up to date — the local copy is the reference everything is diffed
# against. If your template checkout is stale, every repo will falsely read as
# "up to date".
#
# Repo list, in priority order:
#   1. CLI args:   scripts/check-routine-drift.sh owner/repoA owner/repoB
#   2. The Worker: export TODO_INJECTOR_URL and TODO_INJECTOR_SECRET, and the
#      fleet is pulled from the worker's `repos` route (ALLOWED_TARGETS — the
#      single source of truth for which repos are wired in).
#
# Flags:  --show-diff  print the actual diff for each stale repo.
# Env:    ROUTINE_BRANCH  branch to read from (default: main).
# Exit:   0 if every checked repo is up to date; 1 if any drift/missing/error;
#         2 on a usage/setup problem.
#
# Requires: bash 4+, curl, diff, python3 (only for the worker-list path).

set -uo pipefail

BRANCH="${ROUTINE_BRANCH:-main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANON="$SCRIPT_DIR/../.claude/routine-base.md"
SHOW_DIFF=0

ARGS=()
for a in "$@"; do
  case "$a" in
    --show-diff) SHOW_DIFF=1 ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) ARGS+=("$a") ;;
  esac
done

[ -f "$CANON" ] || { echo "canonical copy not found at $CANON — run from the template checkout" >&2; exit 2; }

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

# ---- audit ----------------------------------------------------------------
stale=(); missing=(); errored=(); ok=0
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT

printf '%-45s %s\n' "REPO" "STATUS"
printf '%-45s %s\n' "----" "------"
for repo in "${repos[@]}"; do
  # Cache-buster: raw's CDN caches ~5min by path; a unique query nudges a fresh
  # read where honored (harmless where ignored). A backfill can still take a few
  # minutes to reflect here.
  url="https://raw.githubusercontent.com/${repo}/${BRANCH}/.claude/routine-base.md?_=$(date +%s%N)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null)" || code=000
  if [ "$code" = "200" ]; then
    if diff -q "$CANON" "$tmp" >/dev/null 2>&1; then
      printf '%-45s %s\n' "$repo" "up to date"
      ok=$((ok + 1))
    else
      d="$(diff "$CANON" "$tmp" | grep -cE '^[<>]' || true)"
      printf '%-45s %s\n' "$repo" "STALE   (${d} differing lines)"
      stale+=("$repo")
      if [ "$SHOW_DIFF" = "1" ]; then
        echo "----- diff: template (<) vs ${repo} (>) -----"
        diff "$CANON" "$tmp" || true
        echo "---------------------------------------------"
      fi
    fi
  elif [ "$code" = "404" ]; then
    printf '%-45s %s\n' "$repo" "MISSING (.claude/routine-base.md not on ${BRANCH})"
    missing+=("$repo")
  else
    printf '%-45s %s\n' "$repo" "ERROR   (HTTP ${code})"
    errored+=("$repo")
  fi
done

# ---- summary --------------------------------------------------------------
echo
echo "checked ${#repos[@]}: ${ok} up to date, ${#stale[@]} stale, ${#missing[@]} missing, ${#errored[@]} error"
if [ "${#stale[@]}" -gt 0 ]; then
  echo
  echo "backfill the stale repos — copy this template's .claude/routine-base.md into each and commit:"
  for r in "${stale[@]}"; do echo "  - $r"; done
  echo "(re-run with --show-diff to see exactly what differs.)"
fi

# non-zero exit if anything needs attention (usable as a CI / pre-push gate)
[ "${#stale[@]}" -eq 0 ] && [ "${#missing[@]}" -eq 0 ] && [ "${#errored[@]}" -eq 0 ]
