#!/usr/bin/env bash
#
# offboard.sh — remove the Claude routine scaffolding from an ONBOARDED repo.
# The inverse of onboard.sh.
#
# Usage:
#   ./offboard.sh [--purge] [--dry-run] [--force] [--yes] <path-to-target-repo>
#   ./offboard.sh ~/code/my-project
#
# Bringing a repo UP TO DATE is not this script's job: run onboard.sh with
# refresh=stale (overwrite managed files provably unedited) or refresh=all
# (overwrite the held ones too). This script takes a repo OUT.
#
# What it removes:
#   default   The CHROME files — template-sourced routine files, managed
#             workflows, manifest generators, the generated src-manifest.json
#             — plus the six repo secrets onboard.sh set and the
#             inject_targets registry row. The AUTHORED files stay (CLAUDE.md,
#             .claude/routine.md, the style docs, assignment.md / project.md,
#             TODO.md), so the repo keeps its spec/brief/backlog. Pages and
#             workflow permissions are untouched: a deployed site keeps serving.
#   --purge   The authored files too. A clean slate for re-interviewing a repo
#             or retiring it.
#
# The provenance gate (why a file can be "held"):
#   onboard.sh is skip-existing, so a repo's deploy.yml or test.yml may predate
#   onboarding — same filename, never template-sourced. Deleting by name would
#   destroy it. So a chrome file is deleted ONLY when its bytes provably ARE a
#   template revision: the template's git history for the file is walked,
#   every revision is compared with {{PLACEHOLDER}} lines treated as wildcards
#   (workflow YAMLs inert-stripped first, like routine-compare.sh), and one
#   match is the proof. Anything else is reported as HELD and left in place.
#   --force deletes held files too. The proof needs a full template checkout
#   (offboard.yml checks out with fetch-depth 0); a shallow or absent checkout
#   falls back to the CURRENT template copy only, so a stale-but-unedited file
#   reads as "unknown" and is held — conservative, never destructive.
#
# What is never touched, in any mode:
#   - the project's own source, tests, build output, gh-pages branch
#   - docs/mockups/*.html|svg (only the scaffolded README.md is managed)
#   - GitHub Pages configuration and workflow permissions
#   - any file that is not in the managed catalogue below
#
# Non-interactive (OFFBOARD_NONINTERACTIVE=1, or inferred from CI): every prompt
# auto-answers yes; values come from the environment:
#   OFFBOARD_PURGE=1            same as --purge
#   OFFBOARD_DRY_RUN=1          report only — nothing deleted, no gh call
#   OFFBOARD_FORCE=1            delete held files too
#   OFFBOARD_REPORT_OUT         file to also write the JSON report to
#   GH_TOKEN                    for `gh secret delete`
#   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, ONBOARD_USER_ID
#                               for the inject_targets row delete
#
# Requirements: bash 4.4+, git, standard unix tools (grep, sed, awk, diff). curl
# only for the no-checkout fallback and the registry delete; gh only for secrets.
set -euo pipefail
# ─────────────────────────────────────────────────────────────────
# Configuration — keep in step with onboard.sh.
# ─────────────────────────────────────────────────────────────────
TEMPLATE_OWNER="rsterenchak"
TEMPLATE_REPO="claude-routine-template"
TEMPLATE_BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${TEMPLATE_OWNER}/${TEMPLATE_REPO}/${TEMPLATE_BRANCH}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'
c_red=$'\033[31m'; c_rst=$'\033[0m'
die() { echo "${c_red}error:${c_rst} $*" >&2; exit 1; }
# ─────────────────────────────────────────────────────────────────
# The managed catalogue. UPDATE THIS when onboard.sh's file lists change.
#
# CHROME entries are "DEST|SRC[,SRC...]": DEST is where the file lands in the
# target, SRC the template path(s) that can have produced it. test.yml and
# manifest.yml have several SRCs because onboard.sh writes different template
# files to those names per shape (the SRC>DEST rename) — a repo's test.yml is
# proven by matching ANY of them. scripts/gen-src-manifest.* may also live
# under a WORKING_DIR subfolder (dest_path_for in onboard.sh); those copies
# are discovered by search below, same provenance rule.
# ─────────────────────────────────────────────────────────────────
CHROME=(
  ".claude/routine-base.md|.claude/routine-base.md"
  ".claude/triage.md|.claude/triage.md"
  ".claude/derive.md|.claude/derive.md"
  ".claude/project-derive.md|.claude/project-derive.md"
  ".github/workflows/claude-run.yml|.github/workflows/claude-run.yml"
  ".github/workflows/claude-triage.yml|.github/workflows/claude-triage.yml"
  ".github/workflows/claude-derive.yml|.github/workflows/claude-derive.yml"
  ".github/workflows/claude-scan.yml|.github/workflows/claude-scan.yml"
  ".github/workflows/claude-complexity-scan.yml|.github/workflows/claude-complexity-scan.yml"
  ".github/workflows/run-capture.yml|.github/workflows/run-capture.yml"
  ".github/workflows/test.yml|.github/workflows/test.yml,.github/workflows/test-dotnet.yml,.github/workflows/test-dotnet-windows.yml,.github/workflows/test-maui.yml"
  ".github/workflows/deploy.yml|.github/workflows/deploy.yml"
  ".github/workflows/manifest.yml|.github/workflows/manifest.yml,.github/workflows/manifest-dotnet.yml,.github/workflows/manifest-sql.yml,.github/workflows/manifest-doc.yml"
  "scripts/gen-src-manifest.js|scripts/gen-src-manifest.js"
  "scripts/gen-src-manifest.cjs|scripts/gen-src-manifest.cjs"
  "scripts/render-check.mjs|scripts/render-check.mjs"
  "docs/mockups/README.md|mockups-README.md"
)
# GENERATED: written by a managed workflow, not by onboard.sh, so there is no
# template revision to match. src-manifest.json is deleted when it carries the
# generator's own top-level keys ("files" + "srcRoot") — nothing else writes a
# file of that name with that shape. Checked at the repo root and under the
# same subfolders the generator copies are found in.
GENERATED_NAME="src-manifest.json"
# AUTHORED: interview-filled or hand-edited after onboarding. Purge only, by
# name — there is no canonical form to prove them against, and purge is the
# explicit "everything onboard.sh would have written" request.
AUTHORED=(
  "CLAUDE.md"
  ".claude/routine.md"
  ".claude/style.md"
  ".claude/commenting-style.md"
  "assignment.md"
  "project.md"
  "TODO.md"
)
# Repo secrets onboard.sh sets.
SECRETS=(
  CLAUDE_CODE_OAUTH_TOKEN
  SUPABASE_URL
  SUPABASE_SERVICE_ROLE_KEY
  TODO_INJECTOR_URL
  TODO_INJECTOR_SECRET
  APPETIZE_API_TOKEN
)
# ─────────────────────────────────────────────────────────────────
# Arguments
# ─────────────────────────────────────────────────────────────────
MODE="offboard"; [ -n "${OFFBOARD_PURGE:-}" ] && MODE="purge"
DRY_RUN="${OFFBOARD_DRY_RUN:-}"
FORCE="${OFFBOARD_FORCE:-}"
REPORT_OUT="${OFFBOARD_REPORT_OUT:-}"
NONINTERACTIVE="${OFFBOARD_NONINTERACTIVE:-}"
if [ -z "$NONINTERACTIVE" ] && [ -n "${CI:-}" ]; then NONINTERACTIVE=1; fi
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --purge)     MODE="purge" ;;
    --dry-run)   DRY_RUN=1 ;;
    --force)     FORCE=1 ;;
    --yes|-y)    NONINTERACTIVE=1 ;;
    -h|--help)   sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          die "unknown option: $1" ;;
    *)           [ -z "$TARGET" ] || die "one target only (got '$TARGET' and '$1')"; TARGET="$1" ;;
  esac
  shift
done
[ -n "$TARGET" ] || die "usage: $0 [--purge] [--dry-run] [--force] [--yes] <path-to-target-repo>"
[ -d "$TARGET" ] || die "target directory not found: $TARGET"
TARGET="$(cd "$TARGET" && pwd)"
git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$TARGET is not a git repository"
# Refuse to turn the script on its own home. The template repo carries every
# chrome file by construction; offboarding it would be deleting the source.
if [ -f "$TARGET/onboard.sh" ] && grep -q "^TEMPLATE_REPO=\"${TEMPLATE_REPO}\"" "$TARGET/onboard.sh" 2>/dev/null; then
  die "refusing to offboard the template repo itself ($TARGET)"
fi
# ni_read VAR "prompt" "ni_value" — same contract as onboard.sh.
ni_read() {
  local __niv="$1"; local __nip="$2"; local __nid="$3"
  if [ -n "$NONINTERACTIVE" ]; then printf -v "$__niv" '%s' "$__nid"; return 0; fi
  read -r -p "$__nip" "$__niv"
}
# ─────────────────────────────────────────────────────────────────
# Template history — the proof source. SCRIPT_DIR is a template checkout when
# this script runs from one (offboard.yml, or a laptop clone). A shallow
# checkout can't walk history (same guard as routine-compare.sh), and
# `curl | bash` has no checkout at all; both fall back to the current copy.
# ─────────────────────────────────────────────────────────────────
TEMPLATE_GIT=""
HISTORY_NOTE=""
if [ -f "$SCRIPT_DIR/onboard.sh" ] && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ "$(git -C "$SCRIPT_DIR" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
    HISTORY_NOTE="template checkout is shallow — only the current template copy can be matched (run 'git fetch --unshallow' in $SCRIPT_DIR for the full proof)"
  else
    TEMPLATE_GIT="$SCRIPT_DIR"
  fi
else
  HISTORY_NOTE="no template checkout beside this script — only the current template copy can be matched"
fi
# ─────────────────────────────────────────────────────────────────
# Comparison primitives
# ─────────────────────────────────────────────────────────────────
# Strip whole-line comments and blank lines from a workflow YAML before
# comparing (routine-compare.sh's rc_strip_inert, inlined so this script has no
# sourcing dependency). Comment churn across template revisions must not block
# a proof for a file nobody edited. Prose files are compared exactly.
ob_strip_inert() { # $1=in  $2=out
  sed -E -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$1" > "$2"
}
# Masked line compare: does REPO equal TEMPLATE with every {{KEY}} treated as a
# wildcard? Line counts must agree; a line with no placeholder must match
# exactly; a line with one or more becomes an anchored regex (literal parts
# escaped, placeholders -> .*). This is what lets a RENDERED workflow — real
# WORKING_DIR, real DOTNET_VERSION — be proven against the unrendered template
# without re-running onboard.sh's detection to learn those values.
ob_masked_equal() { # $1=template file  $2=repo file  -> exit 0 on match
  awk '
    function esc(s,   o) { o = s; gsub(/[\\^$.\[\]|()*+?{}]/, "\\\\&", o); return o }
    function line_re(s,   re) {
      re = "^"
      while (match(s, /\{\{[A-Za-z_]+\}\}/)) {
        re = re esc(substr(s, 1, RSTART - 1)) ".*"
        s = substr(s, RSTART + RLENGTH)
      }
      return re esc(s) "$"
    }
    NR == FNR { t[NR] = $0; n = NR; next }
    FNR > n { bad = 1; exit }
    {
      if (index(t[FNR], "{{") == 0) { if ($0 != t[FNR]) { bad = 1; exit } }
      else if ($0 !~ line_re(t[FNR])) { bad = 1; exit }
      m = FNR
    }
    END { if (bad || m != n) exit 1; exit 0 }
  ' "$1" "$2"
}
# Compare one repo file against one template candidate (a file on disk).
ob_candidate_matches() { # $1=dest rel  $2=candidate path  $3=repo path
  local a b rc=1
  case "$1" in
    *.yml|*.yaml)
      a="$(mktemp)"; b="$(mktemp)"
      ob_strip_inert "$2" "$a"; ob_strip_inert "$3" "$b"
      if ob_masked_equal "$a" "$b"; then rc=0; fi
      rm -f "$a" "$b" ;;
    *)
      if ob_masked_equal "$2" "$3"; then rc=0; fi ;;
  esac
  return $rc
}
# Provenance of one repo file. Prints exactly one of:
#   template:<sha>     matches template revision <sha> of SRC (walked history)
#   template:current   matches the current template copy (no history available)
#   local              history walked (or current fetched), nothing matches
#   unknown            no history AND the current copy could not be fetched
ob_provenance() { # $1=dest rel  $2=repo path  $3=comma-separated SRC list
  local dest="$1" repo="$2" srcs="$3" src sha path cand tmp fetched=false
  cand="$(mktemp)"
  if [ -n "$TEMPLATE_GIT" ]; then
    for src in ${srcs//,/ }; do
      # --follow + --name-only prints, per commit, the sha then the path the
      # file had AT that commit — so a file renamed within the template is
      # still walked back through its old name.
      sha=""
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        # A 40-hex line is the next commit; anything else is the file's path
        # at the commit above it (a merge commit may list no path at all).
        if [[ "$line" =~ ^[0-9a-f]{40}$ ]]; then sha="$line"; continue; fi
        [ -n "$sha" ] || continue
        path="$line"
        if git -C "$TEMPLATE_GIT" show "$sha:$path" > "$cand" 2>/dev/null \
           && ob_candidate_matches "$dest" "$cand" "$repo"; then
          rm -f "$cand"; printf 'template:%s\n' "$sha"; return 0
        fi
      done < <(git -C "$TEMPLATE_GIT" log --follow --format=%H --name-only -- "$src" 2>/dev/null || true)
    done
    rm -f "$cand"; printf 'local\n'; return 0
  fi
  # No walkable history: the current copy only. Prefer the file beside this
  # script when it is there (shallow checkout), else fetch it.
  for src in ${srcs//,/ }; do
    tmp=""
    if [ -f "$SCRIPT_DIR/$src" ]; then tmp="$SCRIPT_DIR/$src"
    elif curl -fsSL "$RAW_BASE/$src" -o "$cand" 2>/dev/null; then tmp="$cand"
    fi
    [ -n "$tmp" ] || continue
    fetched=true
    if ob_candidate_matches "$dest" "$tmp" "$repo"; then
      rm -f "$cand"; printf 'template:current\n'; return 0
    fi
  done
  rm -f "$cand"
  if [ "$fetched" = "true" ]; then printf 'local\n'; else printf 'unknown\n'; fi
}
# ─────────────────────────────────────────────────────────────────
# 1. Classify every managed path present in the target
# ─────────────────────────────────────────────────────────────────
DELETE=()        # rel paths that will be removed
DELETE_WHY=()    # one reason per DELETE entry (for the report)
HELD=()          # chrome paths present but not provably template-sourced
HELD_WHY=()
KEEP=()          # authored files present and kept (default mode)
echo
echo "${c_bold}offboard.sh${c_rst} — mode ${c_bold}$MODE${c_rst}${DRY_RUN:+ ${c_yel}(dry run)${c_rst}}${FORCE:+ ${c_yel}(force)${c_rst}}"
echo "  target: ${c_dim}$TARGET${c_rst}"
[ -n "$HISTORY_NOTE" ] && echo "  ${c_yel}note${c_rst}  $HISTORY_NOTE"
echo
# Chrome, at its catalogue path.
for entry in "${CHROME[@]}"; do
  dest="${entry%%|*}"; srcs="${entry#*|}"
  [ -e "$TARGET/$dest" ] || continue
  prov="$(ob_provenance "$dest" "$TARGET/$dest" "$srcs")"
  case "$prov" in
    template:*)
      DELETE+=("$dest"); DELETE_WHY+=("$prov") ;;
    *)
      if [ -n "$FORCE" ]; then DELETE+=("$dest"); DELETE_WHY+=("forced:$prov")
      else HELD+=("$dest"); HELD_WHY+=("$prov"); fi ;;
  esac
done
# Manifest generator copies under a WORKING_DIR subfolder (onboard.sh's
# dest_path_for). node_modules and build output are never managed.
while IFS= read -r found; do
  rel="${found#"$TARGET"/}"
  case "$rel" in scripts/gen-src-manifest.*|scripts/render-check.mjs) continue ;; esac   # root copy handled above
  name="$(basename "$rel")"
  prov="$(ob_provenance "$rel" "$found" "scripts/$name")"
  case "$prov" in
    template:*) DELETE+=("$rel"); DELETE_WHY+=("$prov") ;;
    *) if [ -n "$FORCE" ]; then DELETE+=("$rel"); DELETE_WHY+=("forced:$prov")
       else HELD+=("$rel"); HELD_WHY+=("$prov"); fi ;;
  esac
done < <(find "$TARGET" -type f \( -name 'gen-src-manifest.js' -o -name 'gen-src-manifest.cjs' -o -name 'render-check.mjs' \) \
           -path '*/scripts/*' -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' -not -path '*/bin/*' -not -path '*/obj/*' 2>/dev/null | sort)
# Generated manifest(s): root, plus beside any generator copy found.
while IFS= read -r found; do
  rel="${found#"$TARGET"/}"
  if grep -q '"files"' "$found" 2>/dev/null && grep -q '"srcRoot"' "$found" 2>/dev/null; then
    DELETE+=("$rel"); DELETE_WHY+=("generated")
  else
    HELD+=("$rel"); HELD_WHY+=("not the generator's shape")
  fi
done < <(find "$TARGET" -maxdepth 3 -type f -name "$GENERATED_NAME" \
           -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | sort)
# Authored: purge deletes, the default keeps and says so.
for rel in "${AUTHORED[@]}"; do
  [ -e "$TARGET/$rel" ] || continue
  if [ "$MODE" = "purge" ]; then DELETE+=("$rel"); DELETE_WHY+=("authored:purge")
  else KEEP+=("$rel"); fi
done
# ─────────────────────────────────────────────────────────────────
# 2. Plan
# ─────────────────────────────────────────────────────────────────
echo "${c_bold}Files${c_rst}"
if [ ${#DELETE[@]} -gt 0 ]; then
  for i in "${!DELETE[@]}"; do
    why="${DELETE_WHY[$i]}"
    case "$why" in
      template:current) lbl="matches current template" ;;
      template:*)       lbl="matches template @ ${why#template:}"; lbl="${lbl:0:40}" ;;
      forced:*)         lbl="${c_yel}forced${c_rst} (${why#forced:})" ;;
      generated)        lbl="generated by manifest workflow" ;;
      authored:purge)   lbl="authored — purge" ;;
      *)                lbl="$why" ;;
    esac
    echo "  ${c_red}delete${c_rst}  ${DELETE[$i]}  ${c_dim}$lbl${c_rst}"
  done
fi
for i in "${!HELD[@]}"; do
  case "${HELD_WHY[$i]}" in
    local)   lbl="not a template revision — local edits or pre-dates onboarding" ;;
    unknown) lbl="could not compare — no template history and fetch failed" ;;
    *)       lbl="${HELD_WHY[$i]}" ;;
  esac
  echo "  ${c_yel}held${c_rst}    ${HELD[$i]}  ${c_dim}$lbl${c_rst}"
done
for rel in "${KEEP[@]}"; do
  echo "  ${c_dim}keep    $rel  (authored — purge removes it)${c_rst}"
done
if [ ${#DELETE[@]} -eq 0 ] && [ ${#HELD[@]} -eq 0 ] && [ ${#KEEP[@]} -eq 0 ]; then
  echo "  ${c_dim}nothing managed found — this repo does not look onboarded${c_rst}"
fi
echo
echo "${c_bold}Settings${c_rst}"
echo "  ${c_red}delete${c_rst}  repo secrets: ${SECRETS[*]}"
echo "  ${c_red}delete${c_rst}  inject_targets row (projects routed to it become unrouted — FK is ON DELETE SET NULL)"
echo "  ${c_dim}keep    Pages, workflow permissions (idempotent; a deployed site keeps serving)${c_rst}"
echo
# JSON report — same minimal emitters as onboard.sh's preflight, no jq.
j_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
j_arr() { local out="" x; for x in "$@"; do out="${out:+$out,}\"$(j_esc "$x")\""; done; printf '[%s]' "$out"; }
j_bool() { if [ -n "$1" ]; then printf 'true'; else printf 'false'; fi; }
DEL_JSON=""; HELD_JSON=""
for i in "${!DELETE[@]}"; do DEL_JSON="${DEL_JSON:+$DEL_JSON,}{\"file\":\"$(j_esc "${DELETE[$i]}")\",\"reason\":\"$(j_esc "${DELETE_WHY[$i]}")\"}"; done
for i in "${!HELD[@]}";   do HELD_JSON="${HELD_JSON:+$HELD_JSON,}{\"file\":\"$(j_esc "${HELD[$i]}")\",\"reason\":\"$(j_esc "${HELD_WHY[$i]}")\"}"; done
REPO_FOR_GH="$(git -C "$TARGET" remote get-url origin 2>/dev/null | sed -E 's#\.git$##' | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#' || echo "")"
REPORT_JSON="$(printf '{"mode":"%s","dry_run":%s,"force":%s,"repo":"%s","delete":%s,"held":%s,"keep":%s,"history":"%s"}' \
  "$MODE" "$(j_bool "$DRY_RUN")" "$(j_bool "$FORCE")" "$(j_esc "$REPO_FOR_GH")" \
  "[$DEL_JSON]" "[$HELD_JSON]" "$(j_arr "${KEEP[@]+"${KEEP[@]}"}")" \
  "$([ -n "$TEMPLATE_GIT" ] && echo walked || echo current-only)")"
if [ -n "$DRY_RUN" ]; then
  echo "${c_bold}Dry run — nothing deleted, no settings changed.${c_rst}"
  echo
  echo "<<<OFFBOARD_JSON"
  echo "$REPORT_JSON"
  echo "OFFBOARD_JSON>>>"
  [ -n "$REPORT_OUT" ] && printf '%s\n' "$REPORT_JSON" > "$REPORT_OUT"
  exit 0
fi
[ -n "$REPORT_OUT" ] && printf '%s\n' "$REPORT_JSON" > "$REPORT_OUT"
ni_read confirm "Proceed? [y/N] " "y"
case "$confirm" in [yY]|[yY][eE][sS]) ;; *) echo "  aborted — nothing changed."; exit 0 ;; esac
echo
# ─────────────────────────────────────────────────────────────────
# 3. Delete + commit + push
# `git rm --ignore-unmatch` removes a tracked file from the index and disk in
# one step and is silent for an untracked one; the rm -f after it covers that
# untracked case. Only catalogue paths are ever passed here.
# ─────────────────────────────────────────────────────────────────
PUSH_OK=false
if [ ${#DELETE[@]} -gt 0 ]; then
  echo "${c_bold}Removing files${c_rst}"
  for rel in "${DELETE[@]}"; do
    git -C "$TARGET" rm -q -f --ignore-unmatch -- "$rel" 2>/dev/null || true
    rm -f "$TARGET/$rel"
    echo "  ${c_grn}removed${c_rst} $rel"
  done
  # Fold up directories the scaffold created, now empty. rmdir refuses a
  # non-empty one, which is exactly the guard wanted.
  for d in .claude .github/workflows .github docs/mockups docs scripts; do
    [ -d "$TARGET/$d" ] && rmdir "$TARGET/$d" 2>/dev/null && echo "  ${c_dim}removed empty $d/${c_rst}"
  done
  echo
  TARGET_BRANCH="$(git -C "$TARGET" symbolic-ref --short HEAD 2>/dev/null || echo "main")"
  commit_msg="Remove Claude routine scaffolding ($MODE)"
  echo "${c_bold}Commit + push${c_rst}"
  echo "  ${#DELETE[@]} deletion(s) staged. Target branch: ${c_bold}$TARGET_BRANCH${c_rst}"
  ni_read commit_confirm "  Commit and push now? [Y/n] " "y"
  case "$commit_confirm" in
    ""|[yY]|[yY][eE][sS])
      if git -C "$TARGET" diff --staged --quiet; then
        echo "  ${c_dim}nothing to commit (files were untracked)${c_rst}"
        PUSH_OK=true
      elif git -C "$TARGET" commit -q -m "$commit_msg"; then
        echo "  ${c_grn}committed${c_rst} to $TARGET_BRANCH"
        echo "  ${c_dim}-> pushing to origin/$TARGET_BRANCH...${c_rst}"
        if git -C "$TARGET" push origin "$TARGET_BRANCH"; then
          echo "  ${c_grn}pushed${c_rst}"; PUSH_OK=true
        else
          echo "  ${c_red}push failed${c_rst} — see git output above. Manual retry:"
          echo "       git -C $TARGET push origin $TARGET_BRANCH"
        fi
      else
        echo "  ${c_red}FAILED${c_rst} git commit"
      fi ;;
    *)
      echo "  ${c_dim}-> skipped. The deletions are staged; commit them yourself:${c_rst}"
      echo "       git -C $TARGET commit -m \"$commit_msg\" && git -C $TARGET push origin $TARGET_BRANCH" ;;
  esac
  echo
else
  echo "${c_dim}No files to remove.${c_rst}"
  echo
fi
# ─────────────────────────────────────────────────────────────────
# 4. Secrets + registry
# ─────────────────────────────────────────────────────────────────
SECRETS_DONE=false; REGISTRY_DONE=false
if true; then
  echo "${c_bold}Repo settings${c_rst} (${c_dim}${REPO_FOR_GH:-unknown repo}${c_rst})"
  if [ -z "$REPO_FOR_GH" ]; then
    echo "  ${c_yel}skip${c_rst}   couldn't derive owner/repo from the origin remote — remove secrets and the registry row by hand (see below)"
  elif ! command -v gh >/dev/null 2>&1; then
    echo "  ${c_yel}skip${c_rst}   gh CLI not found — secrets must be removed by hand (see below)"
  elif ! gh auth status >/dev/null 2>&1; then
    echo "  ${c_yel}skip${c_rst}   gh is not authenticated — secrets must be removed by hand (see below)"
  else
    sec_fail=false
    for s in "${SECRETS[@]}"; do
      # A secret that was never set 404s; that is the desired end state, not
      # a failure, so only a non-404 error counts.
      out="$(gh secret delete "$s" --repo "$REPO_FOR_GH" 2>&1)" && { echo "  ${c_grn}deleted${c_rst} secret $s"; continue; }
      if printf '%s' "$out" | grep -qi "not found\|404"; then echo "  ${c_dim}absent  secret $s${c_rst}"
      else echo "  ${c_red}FAILED${c_rst} secret $s: $out"; sec_fail=true; fi
    done
    [ "$sec_fail" = "false" ] && SECRETS_DONE=true
  fi
  if [ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ] && [ -n "${ONBOARD_USER_ID:-}" ] && [ -n "$REPO_FOR_GH" ]; then
    reg_base="${SUPABASE_URL%/}"
    # return=representation so the response says how many rows went — 0 is
    # "was never registered", which is fine, not an error.
    reg_resp="$(curl -sS -X DELETE \
      "$reg_base/rest/v1/inject_targets?repo=eq.$REPO_FOR_GH&user_id=eq.$ONBOARD_USER_ID" \
      -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
      -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
      -H "Prefer: return=representation" 2>/dev/null || echo "ERR")"
    if [ "$reg_resp" = "ERR" ]; then
      echo "  ${c_red}FAILED${c_rst} registry delete (request error) — delete the target in the app's Inject targets list"
    elif printf '%s' "$reg_resp" | grep -q '"id"'; then
      n="$(printf '%s' "$reg_resp" | grep -o '"id"' | wc -l | tr -d ' ')"
      echo "  ${c_grn}deleted${c_rst} inject_targets row ($n) for $REPO_FOR_GH"; REGISTRY_DONE=true
    elif printf '%s' "$reg_resp" | grep -q '"message"\|"code"'; then
      echo "  ${c_red}FAILED${c_rst} registry delete: $(printf '%s' "$reg_resp" | head -c 200)"
    else
      echo "  ${c_dim}absent  no inject_targets row for $REPO_FOR_GH${c_rst}"; REGISTRY_DONE=true
    fi
  else
    echo "  ${c_yel}skip${c_rst}   registry row (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / ONBOARD_USER_ID not all set)"
  fi
  echo
fi
# ─────────────────────────────────────────────────────────────────
# 5. Summary + what is left to do by hand
# ─────────────────────────────────────────────────────────────────
echo "${c_bold}Done${c_rst} — $MODE: ${#DELETE[@]} removed, ${#HELD[@]} held, ${#KEEP[@]} kept."
if [ ${#HELD[@]} -gt 0 ]; then
  echo
  echo "  Held files were not provably template-sourced. Review them; re-run with --force"
  echo "  to remove them too, or delete by hand the ones you know are scaffold."
fi
case "$MODE" in
  *)
    if [ "$SECRETS_DONE" != "true" ] && [ -n "$REPO_FOR_GH" ]; then
      echo
      echo "  Secrets to remove by hand (Settings -> Secrets and variables -> Actions):"
      for s in "${SECRETS[@]}"; do echo "       gh secret delete $s --repo $REPO_FOR_GH"; done
    fi
    if [ "$REGISTRY_DONE" != "true" ]; then
      echo
      echo "  Registry: delete the target for ${REPO_FOR_GH:-this repo} in the app (Inject targets list),"
      echo "  or run offboard.yml, which has the Supabase credentials."
    fi
    echo
    echo "  Untouched on purpose: GitHub Pages, workflow permissions, the gh-pages branch." ;;
esac
echo
