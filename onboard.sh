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
#   5. Inside a Codespace, detects broken cross-repo git auth (the pinned
#      GITHUB_TOKEN is scoped to the launching repo, not the target) and
#      offers to swap git's credential helper to gh's full-user credentials
#      so the upcoming push works.
#   6. Offers to commit + push the files the script just created — staged
#      selectively from a tracked list so the user's other untracked files
#      are left alone. Declining prints the equivalent manual commands.
#   7. Prints a checklist of remaining manual steps with detected values
#      pre-filled where possible.
#
# Requirements: bash, curl, standard unix tools (grep, sed). No npm deps.
# Network access required (fetches from raw.githubusercontent.com).
# For the Codespace auth-fix path: gh CLI (preinstalled in Codespaces).
#
# Design decisions (see the conversation that produced this):
#   - Skip-existing, never clobber: safest default. If a file exists, the
#     script reports it and moves on. You merge manually if needed.
#   - Fetch-from-template: the template repo is the evolving source of truth.
#     This script pulls current versions so improvements propagate.
#   - Detect-then-confirm: auto-detection is a convenience, but you approve
#     the plan before anything is written.
#   - Selective git add: only files this run created are staged for commit.
#     Other untracked content in the target stays untouched.

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
# Files truly universal to EVERY shape (Node web apps and .NET projects):
UNIVERSAL_FILES=(
  "CLAUDE.md"
  "TODO.md"
  ".claude/routine-base.md"
  ".claude/routine.md"
  ".claude/triage.md"
  ".github/workflows/claude-run.yml"
  ".github/workflows/claude-triage.yml"
)
# Node-shape files (build-pipeline + served-from-source): the npm test workflow
# and the manifest generators. Not used by the .NET shapes.
NODE_FILES=(
  ".github/workflows/test.yml"
  "scripts/gen-src-manifest.js"
  "scripts/gen-src-manifest.cjs"
)
# Shape-specific files.
#   build-pipeline (build -> dist/ -> gh-pages): deploy.yml
#   served-from-source (served straight from main): manifest.yml
#   console (.NET console / cross-platform, no web deploy): a dotnet test
#     workflow on ubuntu, fetched from the template as test-dotnet.yml and
#     written to the target as test.yml (the "SRC>DEST" syntax in the fetch
#     loop handles the rename). No manifest generators, no deploy/manifest.
#   desktop (.NET WinForms/WPF — Windows Desktop SDK): same as console but the
#     test workflow runs on windows-latest, because WinForms/WPF don't build on
#     Linux. Fetched from the template as test-dotnet-windows.yml -> test.yml.
#   maui (.NET MAUI mobile): builds the Android head on ubuntu (installs the
#     maui-android workload). No web deploy, no manifest. Fetched from the
#     template as test-maui.yml -> test.yml. Detected BEFORE desktop, since a
#     MAUI multi-target usually lists net*-windows too.
#   sql (.sql schema/migrations repo): no build, no test. Publishes a source
#     manifest in sql mode (CREATE TABLE -> column outline) served from main
#     root, like the .NET manifest path. Gets manifest-sql.yml -> manifest.yml
#     plus the generator; no test workflow.
BUILD_PIPELINE_FILES=( ".github/workflows/deploy.yml" )
SERVED_FROM_SOURCE_FILES=( ".github/workflows/manifest.yml" )
CONSOLE_FILES=( ".github/workflows/test-dotnet.yml>.github/workflows/test.yml" )
DESKTOP_FILES=( ".github/workflows/test-dotnet-windows.yml>.github/workflows/test.yml" )
MAUI_FILES=( ".github/workflows/test-maui.yml>.github/workflows/test.yml" )
# .NET manifest publishing — the (CommonJS) scanner + a publish workflow that
# runs it in csharp mode and serves src-manifest.json from main root (like
# served-from-source), so the Structure tab can fetch a C# repo's file tree.
# Added to all three .NET shapes; repo-only stays manifest-less. The template
# stores the workflow as manifest-dotnet.yml and onboard writes it into the
# target as plain manifest.yml (the SRC>DEST rename, same as test-dotnet.yml).
DOTNET_MANIFEST_FILES=(
  "scripts/gen-src-manifest.js"
  ".github/workflows/manifest-dotnet.yml>.github/workflows/manifest.yml"
)
# SQL manifest publishing — the same scanner run in sql mode + a publish
# workflow that serves src-manifest.json from main root (like served-from-
# source), so the Structure tab gets a Code lens + a SQL table outline. No test
# workflow (nothing to test in a schema repo); the generator alone + its
# publish workflow. Written to the target as plain manifest.yml (SRC>DEST).
SQL_MANIFEST_FILES=(
  "scripts/gen-src-manifest.js"
  ".github/workflows/manifest-sql.yml>.github/workflows/manifest.yml"
)
TEMPLATE_FILES=()  # assembled after shape detection

# Files actually created by THIS run (not skipped as already-existing). Used
# later for selective `git add` so the auto-commit-push step never sweeps up
# files the script didn't author.
files_created=()
WRITE_FILES=true   # set by the create-prompt below; may flip false to skip writes


# ─────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────
c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'
c_red=$'\033[31m'; c_rst=$'\033[0m'

die() { echo "${c_red}error:${c_rst} $*" >&2; exit 1; }
info() { echo "${c_dim}$*${c_rst}"; }
# ─────────────────────────────────────────────────────────────────
# Non-interactive mode
# When ONBOARD_NONINTERACTIVE=1 (set explicitly, or inferred from CI), every
# prompt answer is taken from the environment instead of the terminal, so the
# script can run head-less in CI (onboard.yml drives it this way). Unset ->
# unchanged interactive behavior, so laptop runs are identical to before.
# Value inputs (project name, tokens, Supabase creds) come from ONBOARD_* /
# secret env vars; y/N confirmations get a fixed auto-answer chosen per prompt.
# ─────────────────────────────────────────────────────────────────
NONINTERACTIVE="${ONBOARD_NONINTERACTIVE:-}"
if [ -z "$NONINTERACTIVE" ] && [ -n "${CI:-}" ]; then NONINTERACTIVE=1; fi

# ni_read VAR "prompt" "ni_value" — interactive: read VAR from the terminal;
# non-interactive: VAR=ni_value (no terminal read).
ni_read() {
  local __niv="$1"; local __nip="$2"; local __nid="$3"
  if [ -n "$NONINTERACTIVE" ]; then printf -v "$__niv" '%s' "$__nid"; return 0; fi
  read -r -p "$__nip" "$__niv"
}

# ni_read_secret VAR "prompt" "ni_value" — same, but no echo on the interactive
# read (the caller prints its own hidden-input prompt just above) and no trailing
# newline; the existing 'echo' after the original read still supplies it.
ni_read_secret() {
  local __niv="$1"; local __nip="$2"; local __nid="$3"
  if [ -n "$NONINTERACTIVE" ]; then printf -v "$__niv" '%s' "$__nid"; return 0; fi
  [ -n "$__nip" ] && printf '%s' "$__nip"
  read -rs "$__niv"
}

# enable_pages_main_root "<label suffix>" — enable GitHub Pages serving from
# main/root (served-from-source and the .NET/SQL manifest shapes, which commit
# src-manifest.json to main). A repo with no Pages site yet needs POST to CREATE
# it — PUT only UPDATES an existing site and 404s when there is none, which was
# the "FAILED Pages source config" cause on fresh onboards. POST creates the site
# WITH the source set; a 409 means it already exists (already enabled), so that's
# also success. Any other failure surfaces the real API error instead of being
# swallowed. Non-fatal (always returns 0) — a Pages hiccup shouldn't abort the
# onboard. Sets GH_PAGES_DONE on success.
enable_pages_main_root() {
  local __label="$1" __out __rc=0
  __out=$(gh api -X POST "/repos/$REPO_FOR_GH/pages" \
    -f "source[branch]=main" -f "source[path]=/" 2>&1) || __rc=$?
  if [ "$__rc" -eq 0 ] || printf '%s' "$__out" | grep -qiE "409|already exists"; then
    echo "  ${c_grn}set${c_rst}    Pages source: main branch, root${__label}"
    GH_PAGES_DONE=true
    return 0
  fi
  echo "  ${c_red}FAILED${c_rst} Pages source config (set manually: Settings -> Pages -> main / root)"
  echo "         ${c_dim}${__out}${c_rst}"
  return 0
}

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
# 1b. Already-onboarded detection
# .claude/routine.md is the distinctive signal — only routine-onboarded repos
# have it. TODO.md alone is too common (many repos have one independently).
# If detected, prompt cautiously: re-running is safe (skip-existing handles
# duplicates) but is usually accidental, and the noise wastes a minute.
# Re-running IS legitimate when picking up new template files added after
# first onboarding — so 'y' to continue is allowed.
# ─────────────────────────────────────────────────────────────────
if [ -f "$TARGET/.claude/routine.md" ]; then
  echo "${c_yel}Note:${c_rst} this repo looks already onboarded — found ${c_bold}.claude/routine.md${c_rst}."
  echo "  Re-running is safe (the script never overwrites existing files), but it's"
  echo "  usually accidental. Continue only if you want to pick up template files added"
  echo "  since the first onboarding."
  ni_read reonboard_confirm "  Continue anyway? [y/N] " "y"
  case "$reonboard_confirm" in
    [yY]|[yY][eE][sS]) echo "  -> continuing"; echo ;;
    *) echo "  Aborted. No changes made."; exit 0 ;;
  esac

  # Unpushed-commit guard. A half-finished earlier run can leave scaffold files
  # committed locally but never pushed (e.g. the push 403'd on cross-repo
  # Codespace auth). Those files then read as "already exists", so THIS run skips
  # them AND the commit step stages nothing new — they silently never reach
  # origin, and re-running keeps looping on the same no-op. Surface any unpushed
  # commits here so they get pushed instead of re-diagnosed turns later.
  if git -C "$TARGET" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    ob_ahead="$(git -C "$TARGET" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    if [ "${ob_ahead:-0}" -gt 0 ]; then
      ob_branch="$(git -C "$TARGET" symbolic-ref --short HEAD 2>/dev/null || echo main)"
      echo "  ${c_yel}heads-up:${c_rst} ${c_bold}${ob_ahead}${c_rst} local commit(s) on ${c_bold}${ob_branch}${c_rst} are NOT on origin yet:"
      git -C "$TARGET" log --oneline '@{u}..HEAD' 2>/dev/null | sed 's/^/        /'
      echo "  An earlier run probably committed scaffold files but failed to push. Since"
      echo "  they exist locally now, this run will SKIP them and commit nothing new — so"
      echo "  they never reach origin. Push them first:"
      echo "      ${c_dim}git -C \"$TARGET\" push origin ${ob_branch}${c_rst}"
      echo "      ${c_dim}(403? unset GITHUB_TOKEN && gh auth setup-git, then retry the push)${c_rst}"
      ni_read ob_push_first "  Stop here so you can push first? [Y/n] " "n"
      case "$ob_push_first" in
        [nN]|[nN][oO]) echo "  -> continuing anyway"; echo ;;
        *) echo "  Stopped. Push the commits above, then re-run if you still need files."; exit 0 ;;
      esac
    fi
  fi
fi

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
# web. If detected, it's one of two .NET shapes:
#   console — cross-platform (.NET console / class lib): dotnet test/build on
#             ubuntu, no manifest, no deploy.
#   desktop — WinForms/WPF (Windows Desktop SDK): same, but the test workflow
#             runs on windows-latest because these don't build on Linux.
# We short-circuit the Node detection below for both.
IS_DOTNET="false"
IS_DESKTOP="false"
IS_MAUI="false"
DOTNET_PROJ=""
if find "$TARGET" -maxdepth 2 \( -name '*.csproj' -o -name '*.sln' \) -not -path '*/bin/*' -not -path '*/obj/*' 2>/dev/null | grep -q .; then
  IS_DOTNET="true"
  DOTNET_PROJ="$(find "$TARGET" -maxdepth 2 \( -name '*.csproj' -o -name '*.sln' \) -not -path '*/bin/*' -not -path '*/obj/*' 2>/dev/null | head -1)"
  # Working dir = where the .sln lives, else where the first .csproj lives.
  sln="$(find "$TARGET" -maxdepth 2 -name '*.sln' -not -path '*/bin/*' -not -path '*/obj/*' 2>/dev/null | head -1)"
  anchor="${sln:-$DOTNET_PROJ}"
  WORKING_DIR="$(dirname "${anchor#$TARGET/}")"
  [ "$WORKING_DIR" = "$TARGET" ] && WORKING_DIR="."
  # MAUI signal: <UseMaui>true</UseMaui> or a mobile TFM (-android/-ios/
  # -maccatalyst). Resolved FIRST in the shape block below, because a MAUI
  # multi-target usually also lists net*-windows, which would otherwise trip the
  # desktop signal and misroute it to the windows-latest workflow.
  if find "$TARGET" -maxdepth 3 -name '*.csproj' -not -path '*/bin/*' -not -path '*/obj/*' -print0 2>/dev/null \
       | xargs -0 grep -liE '<UseMaui>[[:space:]]*true|<TargetFrameworks?>[^<]*-android|<TargetFrameworks?>[^<]*-ios|<TargetFrameworks?>[^<]*-maccatalyst' 2>/dev/null \
       | grep -q .; then
    IS_MAUI="true"
  fi
  # Desktop signal: WinForms/WPF or a Windows-target TFM. These need the Windows
  # Desktop targeting packs (ship with the SDK only on Windows), so they route
  # to the desktop shape (windows-latest) instead of console (ubuntu). Scan the
  # .csproj files one level deeper than the anchor — the .sln often sits a folder
  # above the project that actually carries these properties.
  if find "$TARGET" -maxdepth 3 -name '*.csproj' -not -path '*/bin/*' -not -path '*/obj/*' -print0 2>/dev/null \
       | xargs -0 grep -liE '<UseWindowsForms>[[:space:]]*true|<UseWPF>[[:space:]]*true|<TargetFrameworks?>[^<]*-windows' 2>/dev/null \
       | grep -q .; then
    IS_DESKTOP="true"
  fi
fi

IS_ESM="false"
TEST_CMD="(not detected — fill in manually)"
BUILD_CMD="(not detected — fill in manually)"
if [ "$IS_DOTNET" = "true" ]; then
  # .NET project — fixed dotnet commands. console builds cross-platform on
  # ubuntu; desktop (WinForms/WPF) needs windows-latest. Shapes differ only in
  # which test workflow is fetched.
  TEST_CMD="dotnet test"
  BUILD_CMD="dotnet build"
  if [ "$IS_MAUI" = "true" ]; then
    SHAPE="maui"
    SHAPE_REASON="C#/.NET MAUI mobile ($(basename "$DOTNET_PROJ")) — Android head builds on ubuntu"
  elif [ "$IS_DESKTOP" = "true" ]; then
    SHAPE="desktop"
    SHAPE_REASON="C#/.NET desktop GUI ($(basename "$DOTNET_PROJ")) — WinForms/WPF, builds on windows-latest"
  else
    SHAPE="console"
    SHAPE_REASON="C#/.NET project ($(basename "$DOTNET_PROJ")) — no web deploy"
  fi
  WD_ABS="$TARGET"; [ "$WORKING_DIR" != "." ] && WD_ABS="$TARGET/$WORKING_DIR"
  # .NET source layout: .cs files usually live alongside the .csproj, sometimes
  # under src/. Check src/ first, else use the working dir itself.
  if [ -d "$WD_ABS/src" ]; then
    SRC_PREFIX="$([ "$WORKING_DIR" = "." ] && echo "src/" || echo "$WORKING_DIR/src/")"
  else
    SRC_PREFIX="$([ "$WORKING_DIR" = "." ] && echo "" || echo "$WORKING_DIR/")"
  fi
  MANIFEST_VARIANT="(none — $SHAPE project)"
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
  #   build-pipeline: a real build script + a bundler config
  #                   (vite/webpack/rollup, or angular.json — the Angular CLI
  #                   wraps its bundler and exposes no vite/webpack config of
  #                   its own, so angular.json is the equivalent signal). A repo
  #                   with a build script but NO recognized config still lands
  #                   here via the HAS_BUILD-only fallback below, flagged
  #                   "verify" — that path catches Parcel, esbuild, Next, etc.
  #   served-from-source: no build script, OR html served at the repo root with
  #                       no bundler config.
  # ───────────────────────────────────────────────────────────────
  HAS_BUNDLER="false"
  if [ -n "$PKG" ]; then
    pkgdir="$(dirname "$PKG")"
    for cfg in vite.config.js vite.config.ts webpack.config.js webpack.config.cjs rollup.config.js rollup.config.mjs angular.json; do
      [ -f "$pkgdir/$cfg" ] && HAS_BUNDLER="true" && break
    done
  fi
  HAS_BUILD="false"
  [ "${BUILD_CMD#\(}" = "$BUILD_CMD" ] && HAS_BUILD="true"   # BUILD_CMD doesn't start with "(not detected"
  HAS_ROOT_HTML="false"
  [ -f "$TARGET/index.html" ] && HAS_ROOT_HTML="true"
  # SQL shape signal: .sql files present in a repo with no package.json (and not
  # .NET, handled above). A schema/migrations repo — no build, no test, but it
  # DOES publish a source manifest (Code + SQL lens), unlike repo-only.
  HAS_SQL="false"
  if find "$TARGET" -maxdepth 4 -name '*.sql' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | grep -q .; then
    HAS_SQL="true"
  fi

  SHAPE="unknown"
  SHAPE_REASON=""
  if [ -z "$PKG" ] && [ "$HAS_SQL" = "true" ]; then
    # .sql files, no package.json → schema/migrations repo. Walk the repo root
    # (paths emitted repo-root-relative), publish the manifest in sql mode. No
    # build/test workflow — like repo-only, but with a manifest.
    SHAPE="sql"
    SHAPE_REASON="no package.json, no .NET — .sql files present (schema/migrations repo)"
    SRC_PREFIX=""
    TEST_CMD="none (sql — schema/migrations repo)"
    BUILD_CMD="none (sql — schema/migrations repo)"
    MANIFEST_VARIANT="gen-src-manifest.js"
  elif [ "$HAS_BUILD" = "true" ] && [ "$HAS_BUNDLER" = "true" ]; then
    SHAPE="build-pipeline"
    SHAPE_REASON="has a build script and a bundler config"
  elif [ "$HAS_BUILD" != "true" ] && { [ "$HAS_ROOT_HTML" = "true" ] || [ -d "$WD_ABS/src" ]; }; then
    SHAPE="served-from-source"
    SHAPE_REASON="no build script; files served directly (root index.html and/or src/)"
  elif [ "$HAS_BUILD" = "true" ]; then
    SHAPE="build-pipeline"
    SHAPE_REASON="has a build script (no bundler config detected — verify)"
  elif [ -z "$PKG" ] && [ "$HAS_ROOT_HTML" != "true" ] && [ ! -d "$WD_ABS/src" ]; then
    # Nothing buildable or servable and not .NET: SQL scripts, docs, notes,
    # study repos. The routine + TODO.md still work as a backlog/storage tracker,
    # but there's nothing to build, test, or deploy — so no test/deploy/manifest.
    SHAPE="repo-only"
    SHAPE_REASON="no package.json, no web entry point, no .NET — backlog/storage repo (no build/test/deploy)"
    TEST_CMD="none (repo-only)"
    BUILD_CMD="none (repo-only)"
    MANIFEST_VARIANT="(none — repo-only)"
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
if [ "$SHAPE" = "console" ] || [ "$SHAPE" = "desktop" ] || [ "$SHAPE" = "maui" ]; then
  echo "  language:         C# / .NET"
  echo "  manifest variant: gen-src-manifest.js (csharp mode — published to Pages)"
elif [ "$SHAPE" = "sql" ]; then
  echo "  type:             SQL (schema/migrations repo — no build, test, or deploy)"
  echo "  manifest variant: gen-src-manifest.js (sql mode — published to Pages)"
elif [ "$SHAPE" = "repo-only" ]; then
  echo "  type:             backlog/storage repo (no build, test, or deploy)"
  echo "  manifest variant: none (repo-only — no manifest publishing)"
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
echo "  ${c_dim}console          -> dotnet test (ubuntu) + publish src-manifest.json to Pages${c_rst}"
echo "  ${c_dim}desktop          -> dotnet test (windows-latest, WinForms/WPF) + manifest to Pages${c_rst}"
echo "  ${c_dim}maui             -> dotnet MAUI Android build (ubuntu) + manifest to Pages${c_rst}"
echo "  ${c_dim}sql              -> .sql schema/migrations: publish table-outline manifest to Pages${c_rst}"
echo "  ${c_dim}repo-only        -> backlog/storage repo: routine + TODO only, no test/deploy/manifest${c_rst}"
echo
if [ "$SHAPE" = "console" ] || [ "$SHAPE" = "desktop" ] || [ "$SHAPE" = "maui" ]; then
  ni_read shape_confirm "Detected a C#/.NET $SHAPE project. Correct? [Y/n, or 'build'/'served'/'console'/'desktop'/'maui'/'sql'/'repo' to override] " "${ONBOARD_SHAPE:-y}"
else
  ni_read shape_confirm "Is the deploy shape correct? [Y/n, or type 'build'/'served'/'console'/'desktop'/'maui'/'sql'/'repo' to override] " "${ONBOARD_SHAPE:-y}"
fi
case "$shape_confirm" in
  ""|[yY]|[yY][eE][sS]) ;;
  build*) SHAPE="build-pipeline"; echo "  -> overridden to build-pipeline" ;;
  served*) SHAPE="served-from-source"; echo "  -> overridden to served-from-source" ;;
  console*|[cC]) SHAPE="console"; echo "  -> overridden to console" ;;
  desktop*|[dD]) SHAPE="desktop"; echo "  -> overridden to desktop" ;;
  maui*|[mM]) SHAPE="maui"; echo "  -> overridden to maui" ;;
  [sS][qQ][lL]*) SHAPE="sql"; echo "  -> overridden to sql" ;;
  repo*|none*|[rR]) SHAPE="repo-only"; echo "  -> overridden to repo-only" ;;
  [nN]|[nN][oO])
    echo "Which shape? Type 'build', 'served', 'console', 'desktop', 'maui', 'sql', or 'repo':"
    ni_read shape_pick "" "${ONBOARD_SHAPE:-repo}"
    case "$shape_pick" in
      build*) SHAPE="build-pipeline" ;;
      served*) SHAPE="served-from-source" ;;
      console*|[cC]) SHAPE="console" ;;
      desktop*|[dD]) SHAPE="desktop" ;;
      maui*|[mM]) SHAPE="maui" ;;
      [sS][qQ][lL]*) SHAPE="sql" ;;
      repo*|none*|[rR]) SHAPE="repo-only" ;;
      *) echo "Unrecognized. Aborting — re-run and pick build, served, console, desktop, maui, sql, or repo."; exit 1 ;;
    esac
    echo "  -> set to $SHAPE"
    ;;
  *) echo "Unrecognized response. Aborting."; exit 1 ;;
esac
echo

# ─────────────────────────────────────────────────────────────────
# 2b. Project purpose — personal vs assignment
# This drives CLAUDE.md customization. The template ships with an
# ASSIGNMENT CONTEXT block (sections for spec, constraints, submission
# details). For personal projects, that block gets stripped after the
# CLAUDE.md is written. For coursework, it stays for the user to fill in.
# Defaults to "personal" — the cautious choice, since stripping an unused
# block is reversible (user can paste it back) but cluttering every
# personal repo with unused coursework sections is friction.
# ─────────────────────────────────────────────────────────────────
echo "${c_bold}What's this project for?${c_rst}"
echo "  ${c_dim}Personal: a project you're building for yourself, work, or open source.${c_rst}"
echo "  ${c_dim}Assignment: coursework or a graded assignment with a spec, constraints, due date.${c_rst}"
ni_read purpose_pick "  [P]ersonal (default) / [A]ssignment: " "${ONBOARD_PURPOSE:-P}"
case "$purpose_pick" in
  ""|[pP]|[pP][eE][rR]*) PURPOSE="personal" ;;
  [aA]|[aA][sS][sS]*) PURPOSE="assignment" ;;
  *) PURPOSE="personal"; echo "  ${c_yel}note${c_rst}  unrecognized response, defaulting to personal" ;;
esac
echo "  -> $PURPOSE"
echo

# ─────────────────────────────────────────────────────────────────
# 2c. Optional gh CLI integration
# Detects the GitHub CLI and (if installed and authenticated) offers to
# auto-configure repo settings during onboarding: workflow permissions,
# Pages source, and optionally the CLAUDE_CODE_OAUTH_TOKEN secret. Each of
# these is otherwise a manual step in the post-onboarding checklist.
# Silent when gh is not installed (no nag). When installed-but-not-authed,
# surfaces a one-time hint about gh auth login.
# ─────────────────────────────────────────────────────────────────
USE_GH=false
GH_INSTALLED=false
if command -v gh >/dev/null 2>&1; then
  GH_INSTALLED=true
  if gh auth status >/dev/null 2>&1; then
    echo "${c_bold}gh CLI detected and authenticated${c_rst}"
    echo "  ${c_dim}Can auto-configure: workflow permissions, Pages source, and the OAuth token secret.${c_rst}"
    echo "  ${c_dim}Saying no falls back to manual instructions (current behavior).${c_rst}"
    ni_read gh_confirm "  Auto-configure these via gh CLI? [Y/n] " "y"
    case "$gh_confirm" in
      ""|[yY]|[yY][eE][sS]) USE_GH=true; echo "  -> will auto-configure after file creation" ;;
      *) USE_GH=false; echo "  -> skipping gh auto-config, will print manual steps as usual" ;;
    esac
    echo
  else
    echo "${c_yel}note${c_rst}  gh CLI is installed but not authenticated."
    echo "        Run ${c_bold}gh auth login${c_rst} once to enable auto-configuration of repo"
    echo "        settings on future onboardings. Falling back to manual instructions this run."
    echo
  fi
fi

# Assemble the active file list. Universal files for every shape; Node shapes
# also get the npm test workflow + manifest generators; then the shape-specific
# workflow. The .NET shapes (console/desktop) skip NODE_FILES entirely (no npm
# test, no manifest generators) and bring their own dotnet test workflow.
TEMPLATE_FILES=( "${UNIVERSAL_FILES[@]}" )
case "$SHAPE" in
  build-pipeline)
    TEMPLATE_FILES+=( "${NODE_FILES[@]}" "${BUILD_PIPELINE_FILES[@]}" )
    ;;
  served-from-source)
    TEMPLATE_FILES+=( "${NODE_FILES[@]}" "${SERVED_FROM_SOURCE_FILES[@]}" )
    ;;
  console)
    TEMPLATE_FILES+=( "${CONSOLE_FILES[@]}" "${DOTNET_MANIFEST_FILES[@]}" )
    ;;
  desktop)
    TEMPLATE_FILES+=( "${DESKTOP_FILES[@]}" "${DOTNET_MANIFEST_FILES[@]}" )
    ;;
  maui)
    TEMPLATE_FILES+=( "${MAUI_FILES[@]}" "${DOTNET_MANIFEST_FILES[@]}" )
    ;;
  sql)
    TEMPLATE_FILES+=( "${SQL_MANIFEST_FILES[@]}" )   # manifest only — nothing to test
    ;;
  repo-only)
    : # universal files only — no test/deploy/manifest workflow
    ;;
esac

# Coursework repos also get a stub assignment.md at the repo root. It carries
# the assignment spec / rubric / constraints (read by the agent and the PWA's
# assignment card), keeping CLAUDE.md a pure conventions file. Purpose is
# orthogonal to shape, so it's appended after the shape case — every assignment
# shape gets it, personal repos get none. Flows through the normal fetch +
# skip-existing + commit machinery below; no {{placeholders}} to fill.
if [ "$PURPOSE" = "assignment" ]; then
  TEMPLATE_FILES+=( "assignment.md" ".claude/derive.md" ".github/workflows/claude-derive.yml" "commenting-style.md" )
fi

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
ni_read confirm "Proceed with creating the missing files above? [y/N] " "y"
case "$confirm" in
  [yY]|[yY][eE][sS]) WRITE_FILES=true ;;
  *) WRITE_FILES=false
     echo "  No new files will be written. Repo settings below (Pages, workflow"
     echo "  permissions) still apply — they're idempotent and safe to re-run." ;;
esac
echo

# ─────────────────────────────────────────────────────────────────
# 4. Fetch + write (skip-existing)
# ─────────────────────────────────────────────────────────────────
created=0; skipped=0; failed=0
if [ "$WRITE_FILES" = "true" ]; then
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
    files_created+=("$dest_rel")
  else
    echo "  ${c_red}FAILED${c_rst}  $dest_rel  (could not fetch from template — check network / template repo)"
    failed=$((failed+1))
  fi
done
echo
echo "${c_bold}Summary:${c_rst} $created created, $skipped skipped (existed), $failed failed."
echo
fi   # end "$WRITE_FILES" guard around the fetch/write loop

# ─────────────────────────────────────────────────────────────────
# 4a. CLAUDE.md customization — resolve the ASSIGNMENT CONTEXT block per purpose.
# The template's CLAUDE.md ships with an ASSIGNMENT CONTEXT block (start marker
# through END marker). We never keep it as-is now: the assignment spec lives in
# its own assignment.md, so CLAUDE.md stays a conventions file. Per purpose:
#   personal   — strip the block entirely (clutter for a non-coursework repo).
#   assignment — replace the block with a one-line pointer at assignment.md,
#                where the spec / rubric / constraints actually live.
# The grep for the template marker is the gate — it only matches the freshly
# fetched template CLAUDE.md, so a user's pre-existing CLAUDE.md (skipped as
# already-existing, marker absent) is never touched. Idempotent on re-onboard:
# once transformed, the marker is gone and this is a no-op.
# ─────────────────────────────────────────────────────────────────
CLAUDE_MD_TARGET="$TARGET/CLAUDE.md"
if [ -f "$CLAUDE_MD_TARGET" ] && grep -q "ASSIGNMENT CONTEXT — fill in if this is coursework" "$CLAUDE_MD_TARGET"; then
  if [ "$PURPOSE" = "personal" ]; then
    # Delete the block (start marker through END marker, inclusive).
    # Temp-file pattern is portable across GNU and BSD sed.
    sed '/ASSIGNMENT CONTEXT — fill in if this is coursework/,/END ASSIGNMENT CONTEXT/d' \
        "$CLAUDE_MD_TARGET" > "$CLAUDE_MD_TARGET.tmp" \
        && mv "$CLAUDE_MD_TARGET.tmp" "$CLAUDE_MD_TARGET"
    # Cleanup: deletion may have left two consecutive '---' separators where
    # the block was bordered by them. Collapse to one.
    awk 'BEGIN{prev_sep=0}
         /^---$/ { if (prev_sep) next; prev_sep=1; print; next }
         /^$/ { print; next }
         { prev_sep=0; print }' \
        "$CLAUDE_MD_TARGET" > "$CLAUDE_MD_TARGET.tmp" \
        && mv "$CLAUDE_MD_TARGET.tmp" "$CLAUDE_MD_TARGET"
    echo "  ${c_dim}stripped ASSIGNMENT CONTEXT block from CLAUDE.md (personal project)${c_rst}"
    echo
  else
    # Assignment: replace the block (start marker through END marker, inclusive)
    # with a short pointer at assignment.md. The '---' separators bordering the
    # block stay, so the pointer reads as its own clean section.
    awk '
      /ASSIGNMENT CONTEXT — fill in if this is coursework/ {
        print "## Assignment context";
        print "";
        print "This repo is coursework. The assignment spec, rubric, and constraints live in `assignment.md` at the repo root — read it when working here. Keep this file (CLAUDE.md) for build and code conventions.";
        print "";
        print "Code you write for this assignment MUST follow the commenting style in `commenting-style.md` at the repo root — read it before writing or editing any source file.";
        inblock = 1;
        next
      }
      /END ASSIGNMENT CONTEXT/ { inblock = 0; next }
      inblock { next }
      { print }
    ' "$CLAUDE_MD_TARGET" > "$CLAUDE_MD_TARGET.tmp" \
        && mv "$CLAUDE_MD_TARGET.tmp" "$CLAUDE_MD_TARGET"
    echo "  ${c_dim}pointed CLAUDE.md at assignment.md (assignment project)${c_rst}"
    echo
  fi
fi

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

ni_read IN_NAME "  Project name [${NAME_DEFAULT}]: " "${ONBOARD_NAME:-}"
PROJECT_NAME="${IN_NAME:-$NAME_DEFAULT}"

ni_read IN_DESC "  One-line description: " "${ONBOARD_DESC:-}"
PROJECT_DESCRIPTION="${IN_DESC:-(fill in a one-line description)}"

STACK_DEFAULT="$([ "$IS_ESM" = "true" ] && echo "ESM (type: module)" || echo "CommonJS")"
ni_read IN_STACK "  Stack [${STACK_DEFAULT}]: " "${ONBOARD_STACK:-}"
STACK="${IN_STACK:-$STACK_DEFAULT}"

# Derived defaults for the remaining slots, falling back to readable hints when
# detection failed (so a non-filled placeholder reads as an obvious TODO, not a
# literal {{...}} that could slip into a committed workflow file).
SRC_DIR_VAL="$SRC_PREFIX"; [ "${SRC_DIR_VAL#\(}" != "$SRC_DIR_VAL" ] && SRC_DIR_VAL="src/"
TEST_DIR_VAL="tests/"
DOTNET_VERSION_VAL=""
MANIFEST_SRC_ROOT_VAL=""
if [ "$SHAPE" = "console" ] || [ "$SHAPE" = "desktop" ] || [ "$SHAPE" = "maui" ]; then
  # .NET defaults (console + desktop + maui share the dotnet command set).
  TEST_CMD_VAL="dotnet test"
  BUILD_CMD_VAL="dotnet build"
  INSTALL_CMD_VAL="dotnet restore"
  BUILD_DIR_VAL="bin/"
  DEPLOY_TARGET_VAL="GitHub Pages (source manifest only — no app deploy)"
  # Scope the csharp manifest walk to this project's folder. Equals the repo's
  # srcPrefix sans trailing slash, so emitted paths start with that prefix —
  # which is what makes the worker resolve them for chat attachment.
  MANIFEST_SRC_ROOT_VAL="${SRC_PREFIX%/}"
  ni_read IN_DOTNET "  .NET SDK version [8.0.x]: " "${ONBOARD_DOTNET:-}"
  DOTNET_VERSION_VAL="${IN_DOTNET:-8.0.x}"
elif [ "$SHAPE" = "sql" ]; then
  # SQL schema/migrations repo — no build pipeline, but it publishes a manifest
  # (sql mode). MANIFEST_SRC_ROOT scopes the .sql walk; blank for a repo whose
  # .sql sit at the root (the common case), which equals the "" srcPrefix in the
  # worker's ALLOWED_TARGETS so emitted paths resolve for chat attachment.
  TEST_CMD_VAL="none"
  BUILD_CMD_VAL="none"
  INSTALL_CMD_VAL="none"
  BUILD_DIR_VAL="n/a"
  DEPLOY_TARGET_VAL="GitHub Pages (source manifest only — no app deploy)"
  SRC_DIR_VAL=""
  MANIFEST_SRC_ROOT_VAL="${SRC_PREFIX%/}"
elif [ "$SHAPE" = "repo-only" ]; then
  # Backlog/storage repo — no build pipeline. These read as "none" in the filled
  # CLAUDE.md/routine.md, which use the values descriptively (not as forced runs).
  TEST_CMD_VAL="none"
  BUILD_CMD_VAL="none"
  INSTALL_CMD_VAL="none"
  BUILD_DIR_VAL="n/a"
  DEPLOY_TARGET_VAL="none (backlog/storage repo)"
  SRC_DIR_VAL=""
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
  ".claude/triage.md"
  ".claude/derive.md"
  ".github/workflows/test.yml"
)
# Add the shape-specific workflow so its placeholders ({{WORKING_DIR}},
# {{BUILD_COMMAND}}, {{MANIFEST_VARIANT}}, {{DOTNET_VERSION}}, etc.) get filled.
case "$SHAPE" in
  build-pipeline)     PLACEHOLDER_FILES+=( ".github/workflows/deploy.yml" ) ;;
  served-from-source) PLACEHOLDER_FILES+=( ".github/workflows/manifest.yml" ) ;;
  console)            PLACEHOLDER_FILES+=( ".github/workflows/manifest.yml" ) ;;
  desktop)            PLACEHOLDER_FILES+=( ".github/workflows/manifest.yml" ) ;;
  maui)               PLACEHOLDER_FILES+=( ".github/workflows/manifest.yml" ) ;;
  sql)                PLACEHOLDER_FILES+=( ".github/workflows/manifest.yml" ) ;;
  repo-only)          : ;;  # repo-only has no shape-specific workflow
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
  subst "$fpath" "MANIFEST_SRC_ROOT" "$MANIFEST_SRC_ROOT_VAL"
done
echo "  ${c_grn}filled${c_rst} placeholders in $(printf '%s, ' "${PLACEHOLDER_FILES[@]}" | sed 's/, $//')"
echo "  ${c_yel}note${c_rst}  the \"Key files\" section of CLAUDE.md and the freeform sections of"
echo "        routine.md are not auto-filled — complete those by hand."
echo

# ─────────────────────────────────────────────────────────────────
# 4c. gh CLI auto-configuration (if consented earlier)
# Runs only when USE_GH=true. Each sub-step is independent — a failure in
# one doesn't block the others, and each prints a clear status line. The
# *_DONE flags drive conditional suppression in the manual-steps output
# below, so the user sees the manual instructions ONLY for steps that
# weren't automated.
# ─────────────────────────────────────────────────────────────────
GH_WORKFLOW_DONE=false
GH_PAGES_DONE=false
GH_PAGES_DEFERRED=false   # build-pipeline: Pages enabling fails until gh-pages exists
GH_SECRET_DONE=false
GH_SUPABASE_DONE=false
GH_INJECTOR_DONE=false
if [ "$USE_GH" = "true" ]; then
  REPO_FOR_GH="$(cd "$TARGET" && git remote get-url origin 2>/dev/null | sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#' || echo "")"
  if [ -z "$REPO_FOR_GH" ] || [ "$REPO_FOR_GH" = "<owner>/<repo>" ]; then
    echo "${c_yel}note${c_rst}  couldn't determine repo from git remote — skipping gh auto-config."
    echo "        Configure GitHub settings manually using the steps below."
    echo
  else
    echo "${c_bold}Configuring GitHub repo settings via gh CLI${c_rst} (${c_dim}$REPO_FOR_GH${c_rst})"

    # 1. Workflow permissions — universal, applies to all shapes.
    # Sets read-write permissions and enables can-approve-pull-request-reviews
    # (needed for claude-run.yml's auto-merge step).
    if gh api -X PUT "/repos/$REPO_FOR_GH/actions/permissions/workflow" \
         -F "default_workflow_permissions=write" \
         -F "can_approve_pull_request_reviews=true" >/dev/null 2>&1; then
      echo "  ${c_grn}set${c_rst}    workflow permissions: read-write + can-approve-PRs"
      GH_WORKFLOW_DONE=true
    else
      echo "  ${c_red}FAILED${c_rst} workflow permissions (set manually in Settings -> Actions -> General -> Workflow permissions)"
    fi

    # 2. Pages source — web shapes only. console/desktop skip entirely.
    case "$SHAPE" in
      build-pipeline)
        # Try-and-catch: if gh-pages branch doesn't exist yet (first onboarding,
        # pre-deploy), the API call fails. That's normal — surface a clear
        # message about re-running after first deploy creates the branch.
        if gh api -X PUT "/repos/$REPO_FOR_GH/pages" \
             -f "source[branch]=gh-pages" -f "source[path]=/" >/dev/null 2>&1; then
          echo "  ${c_grn}set${c_rst}    Pages source: gh-pages branch, root"
          GH_PAGES_DONE=true
        else
          echo "  ${c_yel}skip${c_rst}   Pages enabling (gh-pages branch doesn't exist yet — normal for first onboarding)"
          echo "         After your first deploy creates gh-pages, run:"
          echo "         ${c_dim}gh api -X PUT /repos/$REPO_FOR_GH/pages -f 'source[branch]=gh-pages' -f 'source[path]=/'${c_rst}"
          GH_PAGES_DEFERRED=true
        fi
        ;;
      served-from-source)
        enable_pages_main_root ""
        ;;
      console|desktop|maui|sql)
        # .NET and SQL shapes publish src-manifest.json to Pages (served from
        # main root, like served-from-source) so the Structure tab can fetch it.
        enable_pages_main_root " (serves src-manifest.json)"
        ;;
      repo-only)
        # No Pages for repo-only — no manifest to serve.
        ;;
    esac

    # 3. OAuth secret — optional, prompted separately because it requires the
    # user to provide the token value. Uses read -s to suppress echo (the token
    # never appears on-screen or in shell history).
    ni_read secret_confirm "  Add CLAUDE_CODE_OAUTH_TOKEN secret now? [y/N] " "$([ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo y || echo n)"
    case "$secret_confirm" in
      [yY]|[yY][eE][sS])
        echo -n "    Paste your OAuth token (input hidden, press Enter when done): "
        ni_read_secret oauth_token "" "${CLAUDE_CODE_OAUTH_TOKEN:-}"
        echo
        if [ -n "$oauth_token" ]; then
          if printf '%s' "$oauth_token" | gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo "$REPO_FOR_GH" >/dev/null 2>&1; then
            echo "  ${c_grn}set${c_rst}    CLAUDE_CODE_OAUTH_TOKEN secret"
            GH_SECRET_DONE=true
          else
            echo "  ${c_red}FAILED${c_rst} couldn't set secret (add manually in Settings -> Secrets and variables -> Actions)"
          fi
          unset oauth_token
        else
          echo "  ${c_yel}skip${c_rst}   empty token, skipped"
        fi
        ;;
      *)
        echo "  ${c_dim}-> will need to add the secret manually (see step below)${c_rst}"
        ;;
    esac

    # 4. Supabase secrets — required by claude-triage.yml (reading flagged rows +
    # writing verdicts back). Same two values across ALL your repos (one Supabase
    # project), so this is a paste of the same URL + service_role key each time.
    # claude-run.yml doesn't use them, so they're new here. The service_role key
    # is sensitive (read -s hides it); SUPABASE_URL is the bare public project URL
    # and isn't. Use the LEGACY service_role JWT (the routine's curls send it on
    # the Authorization: Bearer header, which the new sb_secret_... keys reject).
    echo
    ni_read supa_confirm "  Add SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY secrets now? [y/N] " "$([ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ] && echo y || echo n)"
    case "$supa_confirm" in
      [yY]|[yY][eE][sS])
        ni_read supa_url "    SUPABASE_URL (https://<ref>.supabase.co, no /rest/v1): " "${SUPABASE_URL:-}"
        echo -n "    SUPABASE_SERVICE_ROLE_KEY (input hidden, press Enter when done): "
        ni_read_secret supa_key "" "${SUPABASE_SERVICE_ROLE_KEY:-}"
        echo
        if [ -n "$supa_url" ] && [ -n "$supa_key" ]; then
          supa_ok=true
          printf '%s' "$supa_url" | gh secret set SUPABASE_URL --repo "$REPO_FOR_GH" >/dev/null 2>&1 || supa_ok=false
          printf '%s' "$supa_key" | gh secret set SUPABASE_SERVICE_ROLE_KEY --repo "$REPO_FOR_GH" >/dev/null 2>&1 || supa_ok=false
          if [ "$supa_ok" = "true" ]; then
            echo "  ${c_grn}set${c_rst}    SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY secrets"
            GH_SUPABASE_DONE=true
          else
            echo "  ${c_red}FAILED${c_rst} couldn't set Supabase secrets (add manually in Settings -> Secrets and variables -> Actions)"
          fi
          unset supa_key
        else
          echo "  ${c_yel}skip${c_rst}   empty value, skipped"
        fi
        ;;
      *)
        echo "  ${c_dim}-> will need to add the Supabase secrets manually (see step below)${c_rst}"
        ;;
    esac

    # 5. Injector secrets — required by claude-run.yml's post-merge refactor
    # scan step. Same two values across ALL your repos (one Worker), so this is
    # a paste of the same URL + secret each time. Optional: the run step guards
    # on both being present and skips cleanly when they're absent, so a repo
    # opts in by having them. Only a repo whose registry src_prefix points at a
    # JS source tree can actually produce a scan — the Worker's analysis is
    # JS-shaped. TODO_INJECTOR_URL isn't a credential, but it shouldn't be
    # published from a public repo, so it's a secret rather than a literal in
    # the workflow.
    echo
    ni_read inj_confirm "  Add TODO_INJECTOR_URL + TODO_INJECTOR_SECRET secrets now? [y/N] " "$([ -n "${TODO_INJECTOR_URL:-}" ] && [ -n "${TODO_INJECTOR_SECRET:-}" ] && echo y || echo n)"
    case "$inj_confirm" in
      [yY]|[yY][eE][sS])
        ni_read inj_url "    TODO_INJECTOR_URL (https://<worker>.workers.dev): " "${TODO_INJECTOR_URL:-}"
        echo -n "    TODO_INJECTOR_SECRET (input hidden, press Enter when done): "
        ni_read_secret inj_secret "" "${TODO_INJECTOR_SECRET:-}"
        echo
        if [ -n "$inj_url" ] && [ -n "$inj_secret" ]; then
          inj_ok=true
          printf '%s' "$inj_url" | gh secret set TODO_INJECTOR_URL --repo "$REPO_FOR_GH" >/dev/null 2>&1 || inj_ok=false
          printf '%s' "$inj_secret" | gh secret set TODO_INJECTOR_SECRET --repo "$REPO_FOR_GH" >/dev/null 2>&1 || inj_ok=false
          if [ "$inj_ok" = "true" ]; then
            echo "  ${c_grn}set${c_rst}    TODO_INJECTOR_URL + TODO_INJECTOR_SECRET secrets"
            GH_INJECTOR_DONE=true
          else
            echo "  ${c_red}FAILED${c_rst} couldn't set injector secrets (add manually in Settings -> Secrets and variables -> Actions)"
          fi
          unset inj_secret
        else
          echo "  ${c_yel}skip${c_rst}   empty value, skipped"
        fi
        ;;
      *)
        echo "  ${c_dim}-> refactor scan will skip on this repo (see step below)${c_rst}"
        ;;
    esac
    echo
  fi
fi

# ─────────────────────────────────────────────────────────────────
# 4d. Codespace auth auto-fix
# Fresh Codespaces have a pinned $GITHUB_TOKEN env var that's scoped to the
# repo the Codespace was launched from. When onboarding a DIFFERENT target
# repo (the common case for the routine-template Codespace), git push 403s
# because the scoped token doesn't have write access to the target. The fix
# is a small sequence (unset GITHUB_TOKEN -> gh auth login if needed ->
# gh auth setup-git to swap the credential helper), which used to be a
# diagnostic dance the user had to run by hand.
#
# Detection: $CODESPACES=true AND `git ls-remote --heads origin` against the
# target fails. Both signals must fire — non-Codespace environments skip the
# whole block, and Codespaces where push already works (target == launching
# repo, or auth has been previously swapped) also skip.
#
# Fix sequence is gated behind a Y/n prompt so the user can opt out and
# handle auth themselves if their setup is unusual. On Y, the script runs
# the sequence and re-verifies that push works before continuing to the
# commit-and-push step. On failure, prints a diagnostic and falls through
# to the commit-and-push step anyway (which will print the actual git error
# if push still fails — at that point the user has full context to recover).
# ─────────────────────────────────────────────────────────────────
AUTH_FIXED=false
if [ "${CODESPACES:-}" = "true" ]; then
  # Quick capability probe — does ls-remote work against the target's origin?
  # Wrap in `|| true` so set -e doesn't kill the script on the expected
  # failure case (broken auth).
  ls_remote_ok=true
  git -C "$TARGET" ls-remote --heads origin >/dev/null 2>&1 || ls_remote_ok=false

  if [ "$ls_remote_ok" = "false" ]; then
    echo "${c_yel}Codespace auth note:${c_rst} this Codespace's pinned GITHUB_TOKEN doesn't have"
    echo "  write access to the target repo. ${c_bold}git push will fail${c_rst} until git's credentials"
    echo "  are swapped to your full user credentials via gh."
    echo "  ${c_dim}Standard fix: unset GITHUB_TOKEN, gh auth login (if needed), gh auth setup-git.${c_rst}"
    ni_read auth_confirm "  Fix Codespace auth now? [Y/n] " "n"
    case "$auth_confirm" in
      ""|[yY]|[yY][eE][sS])
        echo "  ${c_dim}-> clearing GITHUB_TOKEN for this script's subprocess...${c_rst}"
        unset GITHUB_TOKEN

        # Check whether gh is already authenticated. If yes, we just need to
        # swap the credential helper. If no, launch the interactive login.
        if gh auth status >/dev/null 2>&1; then
          echo "  ${c_dim}-> gh is already authenticated as $(gh api user --jq .login 2>/dev/null || echo 'user'); skipping login${c_rst}"
        else
          echo "  ${c_dim}-> gh not authenticated — launching gh auth login (follow the prompts)${c_rst}"
          echo
          if ! gh auth login; then
            echo
            echo "  ${c_red}gh auth login failed.${c_rst} Falling through to commit/push step — if the push"
            echo "  fails, run gh auth login manually and re-run this script (already-onboarded detection"
            echo "  will let you skip past file creation)."
            echo
          fi
        fi

        # Swap git's credential helper to gh's full-user credentials. This is
        # the step that actually unblocks push — gh auth login alone doesn't
        # touch git's config.
        if gh auth setup-git 2>/dev/null; then
          echo "  ${c_grn}swapped${c_rst} git credential helper to gh (writes persist for this Codespace)"
          # Re-verify
          if git -C "$TARGET" ls-remote --heads origin >/dev/null 2>&1; then
            echo "  ${c_grn}verified${c_rst} target repo is now reachable for git push"
            AUTH_FIXED=true
          else
            echo "  ${c_yel}note${c_rst}    credential helper swapped but ls-remote still fails — push may still 403"
            echo "          (most common cause: gh-authed user doesn't have write access to $REPO_GUESS)"
          fi
        else
          echo "  ${c_red}FAILED${c_rst} gh auth setup-git couldn't update git config"
          echo "          Manual recovery:"
          echo "          ${c_dim}unset GITHUB_TOKEN${c_rst}"
          echo "          ${c_dim}git config --global --unset credential.helper${c_rst}"
          echo "          ${c_dim}gh auth setup-git${c_rst}"
        fi

        echo
        echo "  ${c_dim}Persistence note: GITHUB_TOKEN will reset on every new terminal in this${c_rst}"
        echo "  ${c_dim}Codespace. To make the unset stick across sessions, add it to ~/.bashrc:${c_rst}"
        echo "  ${c_dim}  echo 'unset GITHUB_TOKEN' >> ~/.bashrc${c_rst}"
        echo
        ;;
      *)
        echo "  ${c_dim}-> skipping auth fix. The commit-and-push step below will likely 403${c_rst}"
        echo "  ${c_dim}   on push — if it does, the manual sequence is in the README's Codespace section.${c_rst}"
        echo
        ;;
    esac
  fi
fi

# ─────────────────────────────────────────────────────────────────
# 4e. Auto-commit-and-push the scaffolded files
# Stages only the files this run created (tracked in files_created), so any
# other untracked files in the target repo are left untouched. Detects the
# target's current branch via symbolic-ref; falls back to "main" if HEAD is
# detached. Prompts before staging so the user can decline and review.
#
# On decline, prints the equivalent manual commands (with the actual file
# list and detected branch baked in) for copy-paste use later.
#
# On accept, runs the three commands and surfaces git's output verbatim so
# diagnostics aren't hidden. A failed push doesn't abort the script — the
# Remaining Manual Steps block still prints, and the user can re-attempt.
# ─────────────────────────────────────────────────────────────────
if [ ${#files_created[@]} -gt 0 ]; then
  # Detect target branch
  TARGET_BRANCH="$(git -C "$TARGET" symbolic-ref --short HEAD 2>/dev/null || echo "main")"

  # Compose the manual-recovery command block once, used in both branches.
  manual_cmds=$(printf '       cd %s\n' "$TARGET"
                printf '       git add %s\n' "${files_created[*]}"
                printf '       git commit -m "Scaffold Claude routine pipeline"\n'
                printf '       git push origin %s\n' "$TARGET_BRANCH")

  echo "${c_bold}Commit + push${c_rst}"
  echo "  ${#files_created[@]} files ready to commit. Will stage ONLY the files this run created"
  echo "  (other untracked files in the target are left alone). Target branch: ${c_bold}$TARGET_BRANCH${c_rst}"
  ni_read commit_confirm "  Commit and push the scaffolded files to $TARGET_BRANCH now? [Y/n] " "y"
  case "$commit_confirm" in
    ""|[yY]|[yY][eE][sS])
      # Stage only files this run authored. Use -C so we don't have to cd.
      stage_failed=false
      for rel in "${files_created[@]}"; do
        git -C "$TARGET" add -- "$rel" || stage_failed=true
      done
      if [ "$stage_failed" = "true" ]; then
        echo "  ${c_red}FAILED${c_rst} couldn't stage one or more files. Manual recovery:"
        echo "$manual_cmds"
      else
        # Commit. Allow empty message to fall through to git's default editor only
        # if the canned message would be a no-op (already-committed case).
        if git -C "$TARGET" diff --staged --quiet; then
          echo "  ${c_dim}nothing to commit (files already in a previous commit, or no changes staged)${c_rst}"
        else
          if git -C "$TARGET" commit -m "Scaffold Claude routine pipeline" >/dev/null; then
            echo "  ${c_grn}committed${c_rst} ${#files_created[@]} files to $TARGET_BRANCH"
          else
            echo "  ${c_red}FAILED${c_rst} git commit failed. Manual recovery:"
            echo "$manual_cmds"
          fi
        fi

        # Push. Don't suppress output — diagnostics from a failed push are
        # what the user needs.
        echo "  ${c_dim}-> pushing to origin/$TARGET_BRANCH...${c_rst}"
        if git -C "$TARGET" push origin "$TARGET_BRANCH"; then
          echo "  ${c_grn}pushed${c_rst}    origin/$TARGET_BRANCH is now in sync"
          PUSH_OK=true
        else
          echo
          echo "  ${c_red}push failed${c_rst} (see git output above for the actual error)"
          echo "  Most common causes after this point:"
          echo "    - gh-authed user doesn't have write access to $REPO_GUESS"
          echo "    - branch protection rules require a PR"
          echo "    - the auth swap didn't fully land (try a fresh terminal: 'unset GITHUB_TOKEN && exec bash')"
          echo "  Manual retry:"
          echo "$manual_cmds"
        fi
      fi
      echo
      ;;
    *)
      echo "  ${c_dim}-> skipping commit + push. To do it manually:${c_rst}"
      echo "$manual_cmds"
      echo
      ;;
  esac
fi

# ─────────────────────────────────────────────────────────────────
# 4d. Registry insert (non-interactive / CI only)
# Add this repo to the shared Supabase inject_targets table so the Worker's
# allowlist and the app's workspace list pick it up with no redeploy — the piece
# that makes onboard.yml a single action. Runs only when the scaffold actually
# reached origin (PUSH_OK) and the Supabase creds + user id are present, so a
# registry row never exists for a repo that failed to push. Interactive laptop
# runs skip this (the +Add target UI already registers repos, and a local run
# doesn't have the creds exported anyway). Check-then-insert so re-onboarding an
# already-registered repo is a no-op, not a duplicate row — no assumption about a
# unique constraint on inject_targets.repo.
# ─────────────────────────────────────────────────────────────────
if [ -n "$NONINTERACTIVE" ] && [ "${PUSH_OK:-false}" = "true" ] \
   && [ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ] \
   && [ -n "${ONBOARD_USER_ID:-}" ] && [ -n "${REPO_FOR_GH:-}" ]; then
  echo "${c_bold}Registry${c_rst}"
  reg_base="${SUPABASE_URL%/}"
  reg_nickname="${ONBOARD_NICKNAME:-${PROJECT_NAME:-$REPO_FOR_GH}}"
  reg_src_prefix="${SRC_PREFIX:-}"
  case "$reg_src_prefix" in "("*) reg_src_prefix="" ;; esac
  reg_existing=$(curl -sS \
    "$reg_base/rest/v1/inject_targets?select=id&repo=eq.$REPO_FOR_GH&user_id=eq.$ONBOARD_USER_ID" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" 2>/dev/null || echo "")
  if printf '%s' "$reg_existing" | grep -q '"id"'; then
    echo "  ${c_dim}already registered${c_rst} $REPO_FOR_GH is already an inject target — leaving it as-is"
  else
    reg_payload=$(printf '{"user_id":"%s","nickname":"%s","repo":"%s","file_path":"TODO.md","src_prefix":"%s","shape":"%s","enabled":true}' \
      "$ONBOARD_USER_ID" "$reg_nickname" "$REPO_FOR_GH" "$reg_src_prefix" "$SHAPE")
    reg_status=$(curl -sS -o /dev/null -w '%{http_code}' \
      -X POST "$reg_base/rest/v1/inject_targets" \
      -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
      -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
      -H "Content-Type: application/json" \
      -H "Prefer: return=minimal" \
      -d "$reg_payload" 2>/dev/null || echo "000")
    if [ "$reg_status" = "201" ] || [ "$reg_status" = "200" ] || [ "$reg_status" = "204" ]; then
      echo "  ${c_grn}registered${c_rst} $REPO_FOR_GH in inject_targets (shape: $SHAPE, enabled)"
    else
      echo "  ${c_red}FAILED${c_rst} registry insert returned HTTP $reg_status — add the target manually in the app"
    fi
  fi
  echo
fi

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

  2. Claude GitHub App — already covered by your all-repositories install, so
     no action is needed here. (Only if you later narrow the App's scope would
     you re-add this repo: https://github.com/apps/claude )

EOF

# Step 3: OAuth secret — conditionally show as done if gh auto-config set it.
if [ "$GH_SECRET_DONE" = "true" ]; then
  echo "  3. ${c_grn}[DONE via gh CLI ✓]${c_rst} CLAUDE_CODE_OAUTH_TOKEN secret already set."
  echo
else
  echo "  3. Add CLAUDE_CODE_OAUTH_TOKEN secret to this repo:"
  echo "       Settings -> Secrets and variables -> Actions -> New repository secret"
  echo
fi

# Step 3b: Supabase secrets — needed by claude-triage.yml. Conditionally shown
# as done if gh auto-config set them above.
if [ "${GH_SUPABASE_DONE:-false}" = "true" ]; then
  echo "  3b. ${c_grn}[DONE via gh CLI ✓]${c_rst} SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY secrets already set."
  echo
else
  echo "  3b. Add SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY secrets to this repo (needed for triage):"
  echo "       Settings -> Secrets and variables -> Actions -> New repository secret"
  echo "       SUPABASE_URL = https://<ref>.supabase.co (no /rest/v1); key = the 'secret' Legacy API key"
  echo
fi

# Step 3c: injector secrets — used by claude-run.yml's post-merge refactor scan
# step. Optional: the step skips cleanly without them, and only a repo with a JS
# source tree under its registry src_prefix can produce a scan at all.
if [ "${GH_INJECTOR_DONE:-false}" = "true" ]; then
  echo "  3c. ${c_grn}[DONE via gh CLI ✓]${c_rst} TODO_INJECTOR_URL + TODO_INJECTOR_SECRET secrets already set."
  echo
else
  echo "  3c. ${c_dim}Optional:${c_rst} add TODO_INJECTOR_URL + TODO_INJECTOR_SECRET to enable the refactor scan:"
  echo "       Settings -> Secrets and variables -> Actions -> New repository secret"
  echo "       Only useful for a JS source tree; the run step skips cleanly without them."
  echo
fi

# Step 4: inject registry — the repo must be a row in Supabase inject_targets for
# the Worker allowlist + the app workspace to reach it. Non-interactive (CI) runs
# insert it automatically (result shown in the Registry line above); interactive
# laptop runs don't, so point at the app's + Add target. (The old "edit
# ALLOWED_TARGETS + npm run deploy" step is gone — the allowlist lives in Supabase
# now, not a hardcoded array in the Worker.)
if [ -n "$NONINTERACTIVE" ]; then
  echo "  4. Inject registry — handled automatically in this run; see the Registry line above for the result."
  echo
else
  echo "  4. Register this repo so the Worker + app can reach it — in the app:"
  echo "       Inject settings -> + Add target   (repo: $REPO_GUESS, file: TODO.md)"
  echo
fi

cat <<EOF
  5. Verify the manifest publishes after first deploy, then inject a test entry
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
