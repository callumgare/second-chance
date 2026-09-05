#!/usr/bin/env bash

# prepare-release.sh - Prepare a release of Second Chance
#
# Works out the next version from the conventional commits since the last tag,
# writes it into the Xcode project, regenerates the changelog and release
# notes, then builds and zips a Release-configuration app.
#
# It deliberately stops before committing, tagging and pushing, and prints
# those commands instead — publishing a release stays a decision you make, not
# a side effect of running a script.
#
# Version numbers and changelogs come from cocogitto (`cog`), configured in
# cog.toml. Run --install-hooks once per clone to have it lint commit messages.
#
# Usage:
#   ./prepare-release.sh                  # version from cog
#   ./prepare-release.sh --version 0.4.0  # override the computed version
#   ./prepare-release.sh --dry-run        # report what would change, write nothing
#   ./prepare-release.sh --no-build       # version, changelog and notes only
#   ./prepare-release.sh --skip-tests     # don't run the unit suite first
#   ./prepare-release.sh --raw-logs       # raw xcodebuild output
#   ./prepare-release.sh --install-hooks  # install cog's commit-msg hook, then exit
#

# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$SCRIPT_DIR/SecondChance.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"
DERIVED_DATA_PATH="$SCRIPT_DIR/DerivedData"
RELEASE_DIR="$SCRIPT_DIR/build/release"
CHANGELOG="$SCRIPT_DIR/CHANGELOG.md"
NOTES_FILE="$RELEASE_DIR/RELEASE_NOTES.md"
NOTES_TEMPLATE="$SCRIPT_DIR/.cog/release-notes.tera"

# The targets whose MARKETING_VERSION tracks the release. GamePuppeteer (a test
# harness) and SecondChanceTests are deliberately left alone — they sit at 1.0
# and are never shipped.
VERSIONED_TARGETS_RE='(SecondChance|WrappTemplate)'

# Parse arguments
VERSION_OVERRIDE=""
DRY_RUN=false
NO_BUILD=false
SKIP_TESTS=false
RAW_LOGS=false
INSTALL_HOOKS=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --version)
            [[ $# -ge 2 ]] || { echo "--version needs a value, e.g. --version 0.4.0" >&2; exit 1; }
            VERSION_OVERRIDE="${2#v}"
            shift 2
            ;;
        --dry-run|-n)
            DRY_RUN=true
            shift
            ;;
        --no-build)
            NO_BUILD=true
            shift
            ;;
        --skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        --raw-logs)
            RAW_LOGS=true
            shift
            ;;
        --install-hooks)
            INSTALL_HOOKS=true
            shift
            ;;
        -h|--help)
            sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--version X.Y.Z] [--dry-run] [--no-build] [--skip-tests] [--raw-logs] [--install-hooks]" >&2
            exit 1
            ;;
    esac
done

die() {
    echo -e "${RED}❌ $1${NC}" >&2
    exit 1
}

command -v cog >/dev/null 2>&1 \
    || die "cocogitto not found. Install it with: brew install cocogitto"

HOOK_PATH="$(git -C "$SCRIPT_DIR" rev-parse --git-path hooks/commit-msg)"

if [[ "$INSTALL_HOOKS" == true ]]; then
    cog install-hook --overwrite commit-msg
    echo -e "${GREEN}✅ commit-msg hook installed — non-conventional messages will now be rejected.${NC}"
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------

echo -e "${BLUE}🔍 Checking preconditions...${NC}"

if [[ "$NO_BUILD" == false && "$DRY_RUN" == false ]]; then
    command -v xcbeautify >/dev/null 2>&1 \
        || die "xcbeautify not found. Install it with: brew install xcbeautify"
fi

[[ -f "$PBXPROJ" ]] || die "Can't find $PBXPROJ"
[[ -f "$NOTES_TEMPLATE" ]] || die "Can't find $NOTES_TEMPLATE"

# A dirty tree would get swept into the release commit, and the version bump
# needs to be the only change in it.
if [[ "$DRY_RUN" == false ]] && [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain)" ]]; then
    git -C "$SCRIPT_DIR" status --short
    die "Working tree isn't clean. Commit or stash first (or use --dry-run)."
fi

CURRENT_BRANCH="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    echo -e "${YELLOW}⚠️  On branch '$CURRENT_BRANCH', not main.${NC}"
fi

if [[ ! -x "$HOOK_PATH" ]]; then
    echo -e "${YELLOW}⚠️  cog's commit-msg hook isn't installed here — run '$0 --install-hooks' to lint messages as you commit.${NC}"
fi

# A message cog can't parse is a message that silently vanishes from the
# changelog, so this is worth knowing about — but history that's already been
# pushed can't always be rewritten, so it's a warning rather than a stop.
if ! LINT_OUTPUT="$(cog check 2>&1)"; then
    echo -e "${YELLOW}⚠️  Some commits since the last tag aren't valid conventional commits."
    echo -e "   They will be missing from the release notes:${NC}"
    echo "$LINT_OUTPUT" | grep -E "Commit message:" | sed 's/^/   /'
fi

# ---------------------------------------------------------------------------
# 2. Work out the version
# ---------------------------------------------------------------------------

LAST_TAG="$(git -C "$SCRIPT_DIR" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo "")"

if [[ -n "$VERSION_OVERRIDE" ]]; then
    VERSION="$VERSION_OVERRIDE"
    echo -e "${BLUE}🏷  Version ${GREEN}$VERSION${NC}${BLUE} (from --version)${NC}"
else
    # cog prints the version on stdout and nothing else when it has one to
    # give. When no commit since the last tag warrants a bump it prints an
    # explanation instead and still exits 0, so the output has to be checked
    # rather than the exit status. See cog.toml for which types count.
    BUMPED="$(cog bump --auto --dry-run --skip-untracked 2>/dev/null | tail -1 || true)"

    if [[ ! "$BUMPED" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "No releasable commits since ${LAST_TAG:-the start}. Only feat, fix and breaking changes bump the version — use --version to force a release anyway."
    fi

    VERSION="${BUMPED#v}"
    echo -e "${BLUE}🏷  Version ${GREEN}$VERSION${NC}${BLUE} (cog, up from ${LAST_TAG:-no tag})${NC}"
fi

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "'$VERSION' isn't a three-part semantic version."

if git -C "$SCRIPT_DIR" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    die "Tag v$VERSION already exists."
fi

# CFBundleVersion. Kept monotonic off the commit count, which also means it
# changes every release — WineManager keys its prefix cache on this, so a
# stale cache can't survive an upgrade.
BUILD_NUMBER="$(git -C "$SCRIPT_DIR" rev-list --count HEAD)"

echo -e "${BLUE}🔢 Build number ${GREEN}$BUILD_NUMBER${NC}"

# Just this release's commits, grouped, with no version heading of its own.
NOTES_BODY="$(cog changelog "${LAST_TAG:+$LAST_TAG..}HEAD" --template "$NOTES_TEMPLATE" 2>/dev/null \
    | sed '/./,$!d')"

[[ -n "$NOTES_BODY" ]] || die "cog produced empty release notes for ${LAST_TAG:-the start}..HEAD"

# ---------------------------------------------------------------------------
# 3. Write the version into the Xcode project
# ---------------------------------------------------------------------------

# Resolves each versioned target's build configurations from its
# XCConfigurationList, then rewrites MARKETING_VERSION and
# CURRENT_PROJECT_VERSION only inside those blocks. Reading the UUIDs out of
# the file rather than hardcoding them means this survives Xcode regenerating
# them, and scoping by block means the untouched targets stay untouched.
update_pbxproj() {
    local out="$1"
    awk -v ver="$VERSION" -v build="$BUILD_NUMBER" -v targets="$VERSIONED_TARGETS_RE" '
        # Pass 1: collect the build-configuration UUIDs of the versioned targets.
        FNR == NR {
            if ($0 ~ ("Build configuration list for PBXNativeTarget \"" targets "\" \\*/ = \\{")) {
                inlist = 1
                next
            }
            if (inlist) {
                if ($0 ~ /^\t\t\};/) { inlist = 0; next }
                if ($0 ~ /\/\* (Debug|Release) \*\/,$/) { want[$1] = 1 }
            }
            next
        }

        # Pass 2: rewrite inside those blocks only.
        $0 ~ /^\t\t[0-9A-Za-z]+ \/\* (Debug|Release) \*\/ = \{$/ {
            inblock = ($1 in want)
        }
        inblock && $0 ~ /^\t\t\tname = / { inblock = 0 }

        inblock && $0 ~ /^\t\t\t\tMARKETING_VERSION = / {
            print "\t\t\t\tMARKETING_VERSION = " ver ";"
            marketing++
            next
        }
        inblock && $0 ~ /^\t\t\t\tCURRENT_PROJECT_VERSION = / {
            print "\t\t\t\tCURRENT_PROJECT_VERSION = " build ";"
            project++
            next
        }
        { print }

        END {
            # Both targets have both keys in both configurations. Anything else
            # means the project changed shape and this needs revisiting.
            if (marketing != 4 || project != 4) {
                printf("expected 4 MARKETING_VERSION and 4 CURRENT_PROJECT_VERSION rewrites, made %d and %d\n",
                       marketing, project) > "/dev/stderr"
                exit 1
            }
        }
    ' "$PBXPROJ" "$PBXPROJ" > "$out"
}

# The version currently in the project, read from the same blocks the rewrite
# targets — a plain grep would also pick up the 1.0 that GamePuppeteer and
# SecondChanceTests sit at.
OLD_VERSION="$(awk -v targets="$VERSIONED_TARGETS_RE" '
    FNR == NR {
        if ($0 ~ ("Build configuration list for PBXNativeTarget \"" targets "\" \\*/ = \\{")) { inlist = 1; next }
        if (inlist) {
            if ($0 ~ /^\t\t\};/) { inlist = 0; next }
            if ($0 ~ /\/\* (Debug|Release) \*\/,$/) { want[$1] = 1 }
        }
        next
    }
    $0 ~ /^\t\t[0-9A-Za-z]+ \/\* (Debug|Release) \*\/ = \{$/ { inblock = ($1 in want) }
    inblock && $0 ~ /^\t\t\tname = / { inblock = 0 }
    inblock && $0 ~ /^\t\t\t\tMARKETING_VERSION = / {
        sub(/;$/, "", $NF); print $NF; exit
    }
' "$PBXPROJ" "$PBXPROJ")"

TMP_PBXPROJ="$(mktemp)"
trap 'rm -f "$TMP_PBXPROJ"' EXIT

if ! update_pbxproj "$TMP_PBXPROJ"; then
    die "pbxproj rewrite failed — project.pbxproj left untouched"
fi

if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}🔎 Dry run — would set MARKETING_VERSION $OLD_VERSION → $VERSION in targets matching $VERSIONED_TARGETS_RE:${NC}"
    diff -u "$PBXPROJ" "$TMP_PBXPROJ" | sed -n '3,$p' | sed 's/^/   /' || true
else
    echo -e "${BLUE}📝 Setting version in the Xcode project...${NC}"
    cat "$TMP_PBXPROJ" > "$PBXPROJ"
    echo -e "${GREEN}   ✓ MARKETING_VERSION $OLD_VERSION → $VERSION, CURRENT_PROJECT_VERSION → $BUILD_NUMBER${NC}"
fi

# ---------------------------------------------------------------------------
# 4. Write the changelog and release notes
# ---------------------------------------------------------------------------

if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}🔎 Dry run — release notes would read:${NC}"
    printf '   %s\n' "${NOTES_BODY//$'\n'/$'\n'   }"
else
    echo -e "${BLUE}📰 Writing changelog and release notes...${NC}"
    mkdir -p "$RELEASE_DIR"

    printf '%s\n' "$NOTES_BODY" > "$NOTES_FILE"

    # CHANGELOG.md accumulates: the new section goes on top of what's already
    # there, so previously released notes stay exactly as they were published.
    if [[ -f "$CHANGELOG" ]] && grep -q "^## $VERSION " "$CHANGELOG"; then
        echo -e "${YELLOW}   ⚠️  CHANGELOG.md already has a $VERSION section — leaving it alone.${NC}"
    else
        NEW_CHANGELOG="$(mktemp)"
        {
            if [[ -f "$CHANGELOG" ]]; then
                # Keep the existing file's header, insert above the newest release.
                awk 'BEGIN { done = 0 }
                     /^## / && !done { done = 1; exit }
                     { print }' "$CHANGELOG"
            else
                cat <<'MARKDOWN'
# Changelog

All notable changes to Second Chance. Generated from the commit history by
[cocogitto](https://docs.cocogitto.io); run `./prepare-release.sh` rather than
editing this file by hand.

MARKDOWN
            fi
            printf '## %s — %s\n\n' "$VERSION" "$(date +%Y-%m-%d)"
            printf '%s\n\n' "$NOTES_BODY"
            if [[ -f "$CHANGELOG" ]]; then
                awk 'BEGIN { found = 0 }
                     /^## / { found = 1 }
                     found { print }' "$CHANGELOG"
            fi
        } > "$NEW_CHANGELOG"
        mv "$NEW_CHANGELOG" "$CHANGELOG"
        echo -e "${GREEN}   ✓ CHANGELOG.md${NC}"
    fi

    echo -e "${GREEN}   ✓ ${NOTES_FILE#"$SCRIPT_DIR"/}${NC}"
fi

# ---------------------------------------------------------------------------
# 5. Tests
# ---------------------------------------------------------------------------

if [[ "$DRY_RUN" == false && "$NO_BUILD" == false && "$SKIP_TESTS" == false ]]; then
    echo -e "${BLUE}🧪 Running unit tests...${NC}"
    # run-tests.sh takes its destination from `uname -m` and WrappTemplate is
    # ARCHS = x86_64, so this has to go through Rosetta or it fails at link.
    arch -x86_64 "$SCRIPT_DIR/run-tests.sh" unit \
        || die "Unit tests failed — not building a release from this."
fi

# ---------------------------------------------------------------------------
# 6. Build and package
# ---------------------------------------------------------------------------

if [[ "$DRY_RUN" == true || "$NO_BUILD" == true ]]; then
    echo
    echo -e "${YELLOW}Skipped the build.${NC}"
    exit 0
fi

echo -e "${BLUE}🔨 Building Release configuration...${NC}"

if [[ "$RAW_LOGS" == true ]]; then
    XCBEAUTIFY_OPTIONS="--preserve-unbeautified"
else
    XCBEAUTIFY_OPTIONS=""
fi

# ONLY_ACTIVE_ARCH=NO for the same reason CI sets it: WrappTemplate is
# ARCHS = x86_64 and swift-log needs an x86_64 slice to link against, while
# the app itself wants to stay universal. Building every arch satisfies both,
# and unlike ./build.sh this needs no `arch -x86_64` wrapper — so the shipped
# app is native on Apple Silicon rather than Rosetta-only.
NSUnbufferedIO=YES xcodebuild -project "$PROJECT" \
    -scheme SecondChance \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    ONLY_ACTIVE_ARCH=NO \
    build 2>&1 | xcbeautify $XCBEAUTIFY_OPTIONS

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Second Chance.app"
[[ -d "$APP_PATH" ]] || die "Build reported success but $APP_PATH is missing"

echo -e "${BLUE}📦 Packaging...${NC}"

mkdir -p "$RELEASE_DIR"
ZIP_PATH="$RELEASE_DIR/SecondChance.zip"
rm -f "$ZIP_PATH"
# ditto, not zip: the Wine and ScummVM payloads inside WrappTemplate.app are
# full of symlinks and extended attributes that `zip` would flatten.
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo -e "${GREEN}   ✓ ${ZIP_PATH#"$SCRIPT_DIR"/} ($(du -h "$ZIP_PATH" | cut -f1 | tr -d ' '))${NC}"
echo -e "${GREEN}   ✓ architectures: $(lipo -archs "$APP_PATH/Contents/MacOS/Second Chance" 2>/dev/null || echo "unknown")${NC}"
echo -e "${GREEN}   ✓ sha256: $(shasum -a 256 "$ZIP_PATH" | cut -d' ' -f1)${NC}"

# The app is ad-hoc signed (CODE_SIGN_IDENTITY is "-"), so it isn't notarized.
# On macOS 15+ that means users have to approve it in System Settings →
# Privacy & Security; the Control-click bypass no longer works.
if ! codesign -dv --verbose=2 "$APP_PATH" 2>&1 | grep -q "Authority=Developer ID"; then
    echo -e "${YELLOW}⚠️  Ad-hoc signed, not notarized — first launch needs approval in System Settings → Privacy & Security.${NC}"
fi

# ---------------------------------------------------------------------------
# 7. What's left to do by hand
# ---------------------------------------------------------------------------

cat <<EOF

$(echo -e "${GREEN}✅ v$VERSION is ready.${NC}")

Review, then publish:

  git diff
  git add -A && git commit -m "chore(release): v$VERSION"
  git tag -a "v$VERSION" -m "v$VERSION"
  git push origin "$CURRENT_BRANCH" "v$VERSION"
  gh release create "v$VERSION" "${ZIP_PATH#"$SCRIPT_DIR"/}" \\
      --title "v$VERSION" --notes-file "${NOTES_FILE#"$SCRIPT_DIR"/}"
EOF
