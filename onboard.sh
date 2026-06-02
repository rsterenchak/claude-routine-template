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
#
# Files truly universal to EVERY shape (Node web apps and .NET console apps):
UNIVERSAL_FILES=(
  "CLAUDE.md"
  "TODO.md"
  ".claude/routine-base.md"
  ".claude/routine.md"
  ".github/workflows/claude-run.yml"
)
# Node-shape files (build-pipeline + served-from-source): the npm test workflow
# and the manifest generators. Not used by the console shape.
NODE_FILES=(
  ".github/workflows/test.yml"
  "scripts/gen-src-manifest.js"
  "scripts/gen-src-manifest.cjs"
)
# Shape-specific files.
#   build-pipeline (build -> dist/ -> gh-pages): deploy.yml
#   served-from-source (served straight from main): manifest.yml
#   console (.NET console app, no web deploy): a dotnet test workflow, fetched
#     from the template as test-dotnet.yml and written to the target as test.yml
#     (the "SRC>DEST" syntax in the fetch loop handles the rename). No manifest
#     generators, no deploy/manifest workflow.
BUILD_PIPELINE_FILES=( ".github/workflows/deploy.yml" )
SERVED_FROM_SOURCE_FILES=( ".github/workflows/manifest.yml" )
CONSOLE_FILES=( ".github/workflows/test-dotnet.yml>.github/workflows/test.yml" )
TEMPLATE_FILES=()  # assembled after shape detection


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

# ── .NET / C# detection (runs before Node detection) ──
# A C# project has a .csproj or .sln, no package.json, and doesn't deploy to the
# web. If detected, it's the "console" shape: dotnet test/build commands, no
# manifest publishing, no deploy/manifest workflow — just the routine + a dotnet
# test workflow. We short-circuit the Node detection below.
IS_DOTNET="false"
DOTNET_PROJ=""
if find "$TARGET" -maxdepth 2 \( -name '*.csproj' -o -name '*.sln' \) -not -path '*/bin/*' -not -path '*/obj/*' 2>/dev/null | grep -q .; then
  IS_DOTNET="true"
  DOTNET_PROJ="$(find "$TARGET" -maxdepth 2 \( -name '*.csproj' -o -name '*.sln' \) -not -path '*/bin/*' -not -path '*/obj/*' 2>/dev/null | head -1)"
  # Working dir = where the .sln lives, else where the first .csproj lives.
  sln="$(find "$TARGET" -maxdepth 2 -name '*.sln' -not -path '*/bin/*' -not -path '*/obj/*' 2>/dev/null | head -1)"
  anchor="${sln:-$DOTNET_PROJ}"
  WORKING_DIR="$(dirname "${anchor#$TARGET/}")"
  [ "$WORKING_DIR" = "$TARGET" ] && WORKING_DIR="."
fi

IS_ESM="false"
TEST_CMD="(not detected — fill in manually)"
BUILD_CMD="(not detected — fill in manually)"
if [ "$IS_DOTNET" = "true" ]; then
  # .NET console project — fixed dotnet commands, console shape.
  TEST_CMD="dotnet test"
  BUILD_CMD="dotnet build"
  SHAPE="console"
  SHAPE_REASON="C#/.NET project ($(basename "$DOTNET_PROJ")) — no web deploy"
  WD_ABS="$TARGET"; [ "$WORKING_DIR" != "." ] && WD_ABS="$TARGET/$WORKING_DIR"
  # .NET source layout: .cs files usually live alongside the .csproj, sometimes
  # under src/. Check src/ first, else use the working dir itself.
  if [ -d "$WD_ABS/src" ]; then
    SRC_PREFIX="$([ "$WORKING_DIR" = "." ] && echo "src/" || echo "$WORKING_DIR/src/")"
  else
    SRC_PREFIX="$([ "$WORKING_DIR" = "." ] && echo "" || echo "$WORKING_DIR/")"
  fi
  MANIFEST_VARIANT="(none — console project)"
elif [ -n "$PKG" ] && [ -f "$PKG" ]; then
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

if [ "$IS_DOTNET" != "true" ]; then
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

  # ───────────────────────────────────────────────────────────────
  # 2c. Detect project SHAPE: build-pipeline vs served-from-source.
  #   build-pipeline    — has a build step that outputs to dist/ (or build/),
  #                       published to gh-pages. Gets deploy.yml + dist-mode
  #                       manifest.
  #   served-from-source — no build; files served straight from main's root
  #                       (or a src/ dir). Gets manifest.yml + root-mode manifest.
  # Signals (file-based — the authoritative Pages setting isn't in the repo, so
  # this is a heuristic the user confirms):
  #   build-pipeline: a real build script + a bundler config (vite/webpack/rollup)
  #   served-from-source: no build script, OR html served at the repo root with
  #                       no bundler config.
  # ───────────────────────────────────────────────────────────────
  HAS_BUNDLER="false"
  if [ -n "$PKG" ]; then
    pkgdir="$(dirname "$PKG")"
    for cfg in vite.config.js vite.config.ts webpack.config.js webpack.config.cjs rollup.config.js rollup.config.mjs; do
      [ -f "$pkgdir/$cfg" ] && HAS_BUNDLER="true" && break
    done
  fi
  HAS_BUILD="false"
  [ "${BUILD_CMD#\(}" = "$BUILD_CMD" ] && HAS_BUILD="true"   # BUILD_CMD doesn't start with "(not detected"
  HAS_ROOT_HTML="false"
  [ -f "$TARGET/index.html" ] && HAS_ROOT_HTML="true"

  SHAPE="unknown"
  SHAPE_REASON=""
  if [ "$HAS_BUILD" = "true" ] && [ "$HAS_BUNDLER" = "true" ]; then
    SHAPE="build-pipeline"
    SHAPE_REASON="has a build script and a bundler config"
  elif [ "$HAS_BUILD" != "true" ] && { [ "$HAS_ROOT_HTML" = "true" ] || [ -d "$WD_ABS/src" ]; }; then
    SHAPE="served-from-source"
    SHAPE_REASON="no build script; files served directly (root index.html and/or src/)"
  elif [ "$HAS_BUILD" = "true" ]; then
    SHAPE="build-pipeline"
    SHAPE_REASON="has a build script (no bundler config detected — verify)"
  else
    SHAPE="served-from-source"
    SHAPE_REASON="no build step detected (assuming served-from-source — verify)"
  fi
fi

# ─────────────────────────────────────────────────────────────────
# 3. Show the plan
# ─────────────────────────────────────────────────────────────────
echo "${c_bold}Detected project shape:${c_rst}"
echo "  package.json:     ${PKG:-none found}"
echo "  working dir:      $WORKING_DIR"
if [ "$SHAPE" = "console" ]; then
  echo "  language:         C# / .NET"
  echo "  manifest variant: none (console project — no manifest publishing)"
else
  echo "  module type:      $([ "$IS_ESM" = "true" ] && echo "ESM (\"type\":\"module\")" || echo "CommonJS")"
  echo "  manifest variant: $MANIFEST_VARIANT  (the other will be removed)"
fi
echo "  source dir:       $SRC_PREFIX"
echo "  test command:     $TEST_CMD"
echo "  build command:    $BUILD_CMD"
echo "  ${c_bold}deploy shape:     $SHAPE${c_rst}  ($SHAPE_REASON)"
echo
echo "  ${c_dim}build-pipeline   -> deploy.yml (build, manifest to dist/, publish to gh-pages)${c_rst}"
echo "  ${c_dim}served-from-source -> manifest.yml (regenerate + commit manifest to repo root)${c_rst}"
echo "  ${c_dim}console          -> dotnet test workflow, no deploy, no manifest publishing${c_rst}"
echo
if [ "$SHAPE" = "console" ]; then
  read -r -p "Detected a C#/.NET console project. Correct? [Y/n, or 'build'/'served' to override] " shape_confirm
else
  read -r -p "Is the deploy shape correct? [Y/n, or type 'build'/'served'/'console' to override] " shape_confirm
fi
case "$shape_confirm" in
  ""|[yY]|[yY][eE][sS]) ;;
  build*) SHAPE="build-pipeline"; echo "  -> overridden to build-pipeline" ;;
  served*) SHAPE="served-from-source"; echo "  -> overridden to served-from-source" ;;
  console*|[cC]) SHAPE="console"; echo "  -> overridden to console" ;;
  [nN]|[nN][oO])
    echo "Which shape? Type 'build', 'served', or 'console':"
    read -r shape_pick
    case "$shape_pick" in
      build*) SHAPE="build-pipeline" ;;
      served*) SHAPE="served-from-source" ;;
      console*|[cC]) SHAPE="console" ;;
      *) echo "Unrecognized. Aborting — re-run and pick build, served, or console."; exit 1 ;;
    esac
    echo "  -> set to $SHAPE"
    ;;
  *) echo "Unrecognized response. Aborting."; exit 1 ;;
esac
echo

# Assemble the active file list. Universal files for every shape; Node shapes
# also get the npm test workflow + manifest generators; then the shape-specific
# workflow. The console shape skips NODE_FILES entirely (no npm test, no
# manifest generators) and brings its own dotnet test workflow.
TEMPLATE_FILES=( "${UNIVERSAL_FILES[@]}" )
case "$SHAPE" in
  build-pipeline)
    TEMPLATE_FILES+=( "${NODE_FILES[@]}" "${BUILD_PIPELINE_FILES[@]}" )
    ;;
  served-from-source)
    TEMPLATE_FILES+=( "${NODE_FILES[@]}" "${SERVED_FROM_SOURCE_FILES[@]}" )
    ;;
  console)
    TEMPLATE_FILES+=( "${CONSOLE_FILES[@]}" )
    ;;
esac

echo "${c_bold}Files to create${c_rst} (existing files will be SKIPPED, never overwritten):"
for f in "${TEMPLATE_FILES[@]}"; do
  # Entries may be "SRC>DEST" (fetch SRC from template, write as DEST in target).
  dest_rel="${f##*>}"   # everything after the last '>' (or the whole string if none)
  # skip the non-chosen manifest variant entirely
  if [ "$dest_rel" = "scripts/gen-src-manifest.js" ] && [ "$IS_ESM" = "true" ]; then continue; fi
  if [ "$dest_rel" = "scripts/gen-src-manifest.cjs" ] && [ "$IS_ESM" != "true" ]; then continue; fi
  if [ -e "$TARGET/$dest_rel" ]; then
    echo "  ${c_yel}skip${c_rst}   $dest_rel  (already exists)"
  else
    echo "  ${c_grn}create${c_rst} $dest_rel"
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
  # Entries may be "SRC>DEST": fetch SRC from the template, write as DEST.
  if [ "$f" != "${f%>*}" ]; then
    src_rel="${f%%>*}"   # before the first '>'
    dest_rel="${f##*>}"  # after the last '>'
  else
    src_rel="$f"; dest_rel="$f"
  fi
  # skip the non-chosen manifest variant
  if [ "$dest_rel" = "scripts/gen-src-manifest.js" ] && [ "$IS_ESM" = "true" ]; then continue; fi
  if [ "$dest_rel" = "scripts/gen-src-manifest.cjs" ] && [ "$IS_ESM" != "true" ]; then continue; fi

  dest="$TARGET/$dest_rel"
  if [ -e "$dest" ]; then
    skipped=$((skipped+1))
    continue
  fi
  mkdir -p "$(dirname "$dest")"
  if curl -fsSL "${RAW_BASE}/${src_rel}" -o "$dest"; then
    echo "  ${c_grn}created${c_rst} $dest_rel"
    created=$((created+1))
  else
    echo "  ${c_red}FAILED${c_rst}  $dest_rel  (could not fetch from template — check network / template repo)"
    failed=$((failed+1))
  fi
done
echo
echo "${c_bold}Summary:${c_rst} $created created, $skipped skipped (existed), $failed failed."
echo

REPO_GUESS="$(cd "$TARGET" && git remote get-url origin 2>/dev/null | sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#' || echo "<owner>/<repo>")"

# ─────────────────────────────────────────────────────────────────
# 4b. Fill placeholders — substitute detected + prompted values into the
#     files that contain {{...}} markers. routine-base.md and the manifest
#     scripts have no placeholders and are left alone. The "Key files" section
#     of CLAUDE.md and the comment-guided sections of routine.md are freeform
#     and can't be auto-filled — you complete those by hand (reminded below).
# ─────────────────────────────────────────────────────────────────
echo "${c_bold}Fill placeholders${c_rst} — press Enter to accept the [detected default], or type a value."
echo

# Default project name = repo basename (from the remote guess, or dir name).
NAME_DEFAULT="$(basename "$REPO_GUESS")"
[ "$NAME_DEFAULT" = "<repo>" ] && NAME_DEFAULT="$(basename "$TARGET")"

read -r -p "  Project name [${NAME_DEFAULT}]: " IN_NAME
PROJECT_NAME="${IN_NAME:-$NAME_DEFAULT}"

read -r -p "  One-line description: " IN_DESC
PROJECT_DESCRIPTION="${IN_DESC:-(fill in a one-line description)}"

STACK_DEFAULT="$([ "$IS_ESM" = "true" ] && echo "ESM (type: module)" || echo "CommonJS")"
read -r -p "  Stack [${STACK_DEFAULT}]: " IN_STACK
STACK="${IN_STACK:-$STACK_DEFAULT}"

# Derived defaults for the remaining slots, falling back to readable hints when
# detection failed (so a non-filled placeholder reads as an obvious TODO, not a
# literal {{...}} that could slip into a committed workflow file).
SRC_DIR_VAL="$SRC_PREFIX"; [ "${SRC_DIR_VAL#\(}" != "$SRC_DIR_VAL" ] && SRC_DIR_VAL="src/"
TEST_DIR_VAL="tests/"
DOTNET_VERSION_VAL=""
if [ "$SHAPE" = "console" ]; then
  # .NET console defaults.
  TEST_CMD_VAL="dotnet test"
  BUILD_CMD_VAL="dotnet build"
  INSTALL_CMD_VAL="dotnet restore"
  BUILD_DIR_VAL="bin/"
  DEPLOY_TARGET_VAL="none (console app)"
  read -r -p "  .NET SDK version [8.0.x]: " IN_DOTNET
  DOTNET_VERSION_VAL="${IN_DOTNET:-8.0.x}"
else
  TEST_CMD_VAL="$TEST_CMD"; [ "${TEST_CMD_VAL#\(}" != "$TEST_CMD_VAL" ] && TEST_CMD_VAL="npm test"
  BUILD_CMD_VAL="$BUILD_CMD"; [ "${BUILD_CMD_VAL#\(}" != "$BUILD_CMD_VAL" ] && BUILD_CMD_VAL="npm run build"
  BUILD_DIR_VAL="dist/"
  INSTALL_CMD_VAL="npm install"
  DEPLOY_TARGET_VAL="GitHub Pages"
fi

# sed-escape a replacement string: backslash, the chosen delimiter (|), and &.
sed_escape() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }

# Apply one {{KEY}} -> value substitution across a file, in place.
subst() { # $1=file  $2=key  $3=value
  local esc; esc="$(sed_escape "$3")"
  sed -i.bak "s|{{$2}}|$esc|g" "$1" && rm -f "$1.bak"
}

# Files that carry placeholders (relative to target). Skip any that were skipped
# during creation (already existed — don't rewrite the user's own file) and any
# that don't exist.
PLACEHOLDER_FILES=(
  "CLAUDE.md"
  ".claude/routine.md"
  ".github/workflows/test.yml"
)
# Add the shape-specific workflow so its placeholders ({{WORKING_DIR}},
# {{BUILD_COMMAND}}, {{MANIFEST_VARIANT}}, {{DOTNET_VERSION}}, etc.) get filled.
case "$SHAPE" in
  build-pipeline)     PLACEHOLDER_FILES+=( ".github/workflows/deploy.yml" ) ;;
  served-from-source) PLACEHOLDER_FILES+=( ".github/workflows/manifest.yml" ) ;;
  console)            : ;;  # console's test.yml is already in the list above
esac
for pf in "${PLACEHOLDER_FILES[@]}"; do
  fpath="$TARGET/$pf"
  [ -f "$fpath" ] || continue
  subst "$fpath" "PROJECT_NAME" "$PROJECT_NAME"
  subst "$fpath" "PROJECT_DESCRIPTION" "$PROJECT_DESCRIPTION"
  subst "$fpath" "STACK" "$STACK"
  subst "$fpath" "WORKING_DIR" "$WORKING_DIR"
  subst "$fpath" "SRC_DIR" "$SRC_DIR_VAL"
  subst "$fpath" "TEST_DIR" "$TEST_DIR_VAL"
  subst "$fpath" "BUILD_DIR" "$BUILD_DIR_VAL"
  subst "$fpath" "INSTALL_COMMAND" "$INSTALL_CMD_VAL"
  subst "$fpath" "TEST_COMMAND" "$TEST_CMD_VAL"
  subst "$fpath" "BUILD_COMMAND" "$BUILD_CMD_VAL"
  subst "$fpath" "DEPLOY_TARGET" "$DEPLOY_TARGET_VAL"
  subst "$fpath" "MANIFEST_VARIANT" "$MANIFEST_VARIANT"
  [ -n "$DOTNET_VERSION_VAL" ] && subst "$fpath" "DOTNET_VERSION" "$DOTNET_VERSION_VAL"
done
echo "  ${c_grn}filled${c_rst} placeholders in $(printf '%s, ' "${PLACEHOLDER_FILES[@]}" | sed 's/, $//')"
echo "  ${c_yel}note${c_rst}  the \"Key files\" section of CLAUDE.md and the freeform sections of"
echo "        routine.md are not auto-filled — complete those by hand."
echo

# ─────────────────────────────────────────────────────────────────
# 5. Remaining manual steps — with detected values pre-filled
# ─────────────────────────────────────────────────────────────────

cat <<EOF
${c_bold}Remaining manual steps:${c_rst}

  1. Complete the freeform sections the script can't auto-fill:
       - CLAUDE.md "Key files in this repo" — list the load-bearing files.
       - CLAUDE.md — delete the onboarding-checklist section once reviewed.
       - .claude/routine.md — fill the project-specific conventions / fragile
         areas / notes sections (or write "none" where nothing applies).
     If WORKING_DIR is ".", also remove the now-redundant working-directory:
     lines from the workflow files (they read "working-directory: .").

  2. Configure the Claude GitHub App for this repo:
       https://github.com/apps/claude

  3. Add CLAUDE_CODE_OAUTH_TOKEN secret to this repo:
       Settings -> Secrets and variables -> Actions -> New repository secret

  4. Add this repo to your GitHub PAT's access list (Contents:write, Actions:read+write):
       https://github.com/settings/personal-access-tokens

  5. Add to todo-injector-worker ALLOWED_TARGETS in src/index.js:
       { repo: "$REPO_GUESS", filePath: "TODO.md", srcPrefix: "$SRC_DIR_VAL" }
     Then: cd todo-injector-worker && npm run deploy

  6. Verify the manifest publishes after first deploy, then inject a test entry
     and confirm claude-run.yml picks it up.

${c_bold}Values that were filled in:${c_rst}
  project name:  $PROJECT_NAME
  description:   $PROJECT_DESCRIPTION
  stack:         $STACK
  working dir:   $WORKING_DIR
  source dir:    $SRC_DIR_VAL
  test command:  $TEST_CMD_VAL
  build command: $BUILD_CMD_VAL
  (review these in the files; re-run with a fresh checkout if any are wrong)

EOF

if [ "$skipped" -gt 0 ]; then
  echo "${c_yel}Note:${c_rst} $skipped file(s) already existed and were skipped — placeholders in"
  echo "      those were NOT touched (the script never edits files it didn't create)."
  echo "      If your repo already has a CLAUDE.md or workflow, merge the template's"
  echo "      content and fill its placeholders by hand."
  echo
fi

echo "${c_grn}Done.${c_rst}"
