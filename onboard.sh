#!/usr/bin/env bash
#
# onboard.sh — add the Claude routine to an EXISTING repository.
#
# Usage:
#   ./onboard.sh <path-to-target-repo>
#   ./onboard.sh ~/code/my-existing-project
#
# What it does:
#   1. Fetches the canonical routine files from the public
#      claude-routine-template repo (always current — no bundled staleness).
#   2. Detects the target project's shape (ESM vs CommonJS, working dir,
#      source dir, test/build commands) from its package.json.
#   3. Shows you a plan of what it will create and what it detected.
#   4. On your confirmation, writes ONLY the files that don't already exist
#      (never clobbers — existing files are reported and skipped).
#   5. Prints a checklist of remaining manual steps with detected values
#      pre-filled where possible.
#
# Requirements: bash, curl, standard unix tools (grep, sed). No npm deps.
# Network access required (fetches from raw.githubusercontent.com).
#
# Design decisions (see the conversation that produced this):
#   - Skip-existing, never clobber: safest default. If a file exists, the
#     script reports it and moves on. You merge manually if needed.
#   - Fetch-from-template: the template repo is the evolving source of truth.
#     This script pulls current versions so improvements propagate.
#   - Detect-then-confirm: auto-detection is a convenience, but you approve
#     the plan before anything is written.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# Configuration — update if your template repo moves.
# ─────────────────────────────────────────────────────────────────
TEMPLATE_OWNER="rsterenchak"
TEMPLATE_REPO="claude-routine-template"
TEMPLATE_BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${TEMPLATE_OWNER}/${TEMPLATE_REPO}/${TEMPLATE_BRANCH}"

# The set of files to fetch from the template, as repo-relative paths.
# UPDATE THIS LIST when you add new files to the template.
# Note: both manifest variants are fetched; the script keeps the right one
# based on detection and deletes the other.
TEMPLATE_FILES=(
  "CLAUDE.md"
  "TODO.md"
  ".claude/routine-base.md"
  ".claude/routine.md"
  ".github/workflows/claude-run.yml"
  ".github/workflows/test.yml"
  ".github/workflows/deploy.yml"
  "scripts/gen-src-manifest.js"
  "scripts/gen-src-manifest.cjs"
)

# ─────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────
c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'
c_red=$'\033[31m'; c_rst=$'\033[0m'

die() { echo "${c_red}error:${c_rst} $*" >&2; exit 1; }
info() { echo "${c_dim}$*${c_rst}"; }

# ─────────────────────────────────────────────────────────────────
# 1. Validate target
# ─────────────────────────────────────────────────────────────────
[ $# -eq 1 ] || die "usage: $0 <path-to-target-repo>"
TARGET="$1"
[ -d "$TARGET" ] || die "target is not a directory: $TARGET"
[ -d "$TARGET/.git" ] || die "target is not a git repo (no .git/): $TARGET"

TARGET="$(cd "$TARGET" && pwd)"  # normalize to absolute
echo "${c_bold}Onboarding target:${c_rst} $TARGET"
echo

# ─────────────────────────────────────────────────────────────────
# 2. Detect project shape
# ─────────────────────────────────────────────────────────────────
# Find package.json — check root first, then one level down (common for
# nested project structures like the canonical toDoList_main/ case).
PKG=""
WORKING_DIR="."
if [ -f "$TARGET/package.json" ]; then
  PKG="$TARGET/package.json"
  WORKING_DIR="."
else
  # look one level deep for a package.json
  while IFS= read -r found; do
    PKG="$found"
    WORKING_DIR="$(dirname "${found#$TARGET/}")"
    break
  done < <(find "$TARGET" -maxdepth 2 -name package.json -not -path '*/node_modules/*' 2>/dev/null)
fi

IS_ESM="false"
TEST_CMD="(not detected — fill in manually)"
BUILD_CMD="(not detected — fill in manually)"
if [ -n "$PKG" ] && [ -f "$PKG" ]; then
  # ESM detection: "type": "module" in package.json
  if grep -Eq '"type"[[:space:]]*:[[:space:]]*"module"' "$PKG"; then
    IS_ESM="true"
  fi
  # Test/build command detection from the scripts block (best-effort grep).
  for key in "test:run" "test:ci" "test"; do
    if grep -Eq "\"$key\"[[:space:]]*:" "$PKG"; then
      TEST_CMD="npm run $key"
      [ "$key" = "test" ] && TEST_CMD="npm test"
      break
    fi
  done
  for key in "build:prod" "build"; do
    if grep -Eq "\"$key\"[[:space:]]*:" "$PKG"; then
      BUILD_CMD="npm run $key"
      break
    fi
  done
else
  info "No package.json found — this may not be a Node project, or the layout is unusual."
  info "WORKING_DIR defaults to '.'; you'll fill in commands manually."
fi

# Source directory detection — look for a src/ relative to the working dir.
SRC_PREFIX="(not detected — fill in manually, e.g. src/)"
WD_ABS="$TARGET"
[ "$WORKING_DIR" != "." ] && WD_ABS="$TARGET/$WORKING_DIR"
for candidate in "src" "app/src" "lib" "source"; do
  if [ -d "$WD_ABS/$candidate" ]; then
    if [ "$WORKING_DIR" = "." ]; then
      SRC_PREFIX="$candidate/"
    else
      SRC_PREFIX="$WORKING_DIR/$candidate/"
    fi
    break
  fi
done

MANIFEST_VARIANT="gen-src-manifest.js"
[ "$IS_ESM" = "true" ] && MANIFEST_VARIANT="gen-src-manifest.cjs"

# ─────────────────────────────────────────────────────────────────
# 3. Show the plan
# ─────────────────────────────────────────────────────────────────
echo "${c_bold}Detected project shape:${c_rst}"
echo "  package.json:     ${PKG:-none found}"
echo "  working dir:      $WORKING_DIR"
echo "  module type:      $([ "$IS_ESM" = "true" ] && echo "ESM (\"type\":\"module\")" || echo "CommonJS")"
echo "  manifest variant: $MANIFEST_VARIANT  (the other will be removed)"
echo "  source dir:       $SRC_PREFIX"
echo "  test command:     $TEST_CMD"
echo "  build command:    $BUILD_CMD"
echo
echo "${c_bold}Files to create${c_rst} (existing files will be SKIPPED, never overwritten):"
for f in "${TEMPLATE_FILES[@]}"; do
  # we'll skip the non-chosen manifest variant entirely
  if [ "$f" = "scripts/gen-src-manifest.js" ] && [ "$IS_ESM" = "true" ]; then continue; fi
  if [ "$f" = "scripts/gen-src-manifest.cjs" ] && [ "$IS_ESM" != "true" ]; then continue; fi
  if [ -e "$TARGET/$f" ]; then
    echo "  ${c_yel}skip${c_rst}   $f  (already exists)"
  else
    echo "  ${c_grn}create${c_rst} $f"
  fi
done
echo
read -r -p "Proceed with creating the missing files above? [y/N] " confirm
case "$confirm" in
  [yY]|[yY][eE][sS]) ;;
  *) echo "Aborted. Nothing written."; exit 0 ;;
esac
echo

# ─────────────────────────────────────────────────────────────────
# 4. Fetch + write (skip-existing)
# ─────────────────────────────────────────────────────────────────
created=0; skipped=0; failed=0
for f in "${TEMPLATE_FILES[@]}"; do
  # skip the non-chosen manifest variant
  if [ "$f" = "scripts/gen-src-manifest.js" ] && [ "$IS_ESM" = "true" ]; then continue; fi
  if [ "$f" = "scripts/gen-src-manifest.cjs" ] && [ "$IS_ESM" != "true" ]; then continue; fi

  dest="$TARGET/$f"
  if [ -e "$dest" ]; then
    skipped=$((skipped+1))
    continue
  fi
  mkdir -p "$(dirname "$dest")"
  if curl -fsSL "${RAW_BASE}/${f}" -o "$dest"; then
    echo "  ${c_grn}created${c_rst} $f"
    created=$((created+1))
  else
    echo "  ${c_red}FAILED${c_rst}  $f  (could not fetch from template — check network / template repo)"
    failed=$((failed+1))
  fi
done
echo
echo "${c_bold}Summary:${c_rst} $created created, $skipped skipped (existed), $failed failed."
echo

# ─────────────────────────────────────────────────────────────────
# 5. Remaining manual steps — with detected values pre-filled
# ─────────────────────────────────────────────────────────────────
REPO_GUESS="$(cd "$TARGET" && git remote get-url origin 2>/dev/null | sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#' || echo "<owner>/<repo>")"

cat <<EOF
${c_bold}Remaining manual steps:${c_rst}

  1. Fill in CLAUDE.md placeholders (then delete its onboarding checklist section).
     Detected values to use:
       {{WORKING_DIR}}  -> $WORKING_DIR
       {{SRC_DIR}}      -> $SRC_PREFIX
       {{TEST_COMMAND}} -> $TEST_CMD
       {{BUILD_COMMAND}}-> $BUILD_CMD

  2. Fill in .claude/routine.md placeholders (same values as above).

  3. Fill in workflow placeholders in .github/workflows/test.yml and deploy.yml:
       {{WORKING_DIR}} -> $WORKING_DIR
     If WORKING_DIR is ".", also remove the working-directory: lines.

  4. Configure the Claude GitHub App for this repo:
       https://github.com/apps/claude

  5. Add CLAUDE_CODE_OAUTH_TOKEN secret to this repo:
       Settings -> Secrets and variables -> Actions -> New repository secret

  6. Add this repo to your GitHub PAT's access list (Contents:write, Actions:read+write):
       https://github.com/settings/personal-access-tokens

  7. Add to todo-injector-worker ALLOWED_TARGETS in src/index.js:
       { repo: "$REPO_GUESS", filePath: "TODO.md", srcPrefix: "$SRC_PREFIX" }
     Then: cd todo-injector-worker && npm run deploy

  8. Verify the manifest publishes after first deploy, then inject a test entry
     and confirm claude-run.yml picks it up.

EOF

if [ "$skipped" -gt 0 ]; then
  echo "${c_yel}Note:${c_rst} $skipped file(s) already existed and were skipped. If your repo"
  echo "      already has a README, workflows, or CLAUDE.md, you may need to merge"
  echo "      the template's content into them manually."
  echo
fi

echo "${c_grn}Done.${c_rst}"
