#!/bin/bash
# run-tests.sh - Second Chance test runner
#
# Usage:
#   ./run-tests.sh [--no-rebuild] [command] [game-slug]
#
# Commands:
#   (none)              Rebuild and run all tests
#   unit | u            Run unit tests only
#   integration | i     Run integration tests (all games, or one if slug given)
#
# Examples:
#   ./run-tests.sh                          Rebuild then run all tests
#   ./run-tests.sh unit                     Rebuild then run unit tests
#   ./run-tests.sh integration              Rebuild then run all integration tests
#   ./run-tests.sh integration haunted-carousel   One game
#   ./run-tests.sh i haunted-carousel       Same, short form
#   ./run-tests.sh --test-existing-wrapper integration haunted-carousel
#                              Skip the install and launch a prebuilt wrapper from built-apps/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIVED_DATA="$SCRIPT_DIR/DerivedData"
REPORTS_DIR="$SCRIPT_DIR/test-results"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Argument parsing ───────────────────────────────────────────────────────────

REBUILD=true
COMMAND="all"
GAME_SLUG=""
SKIP_BUILD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-rebuild)
            REBUILD=false
            shift
            ;;
        --test-existing-wrapper)
            SKIP_BUILD=true
            shift
            ;;
        unit|u)
            COMMAND="unit"
            shift
            ;;
        integration|i)
            COMMAND="integration"
            shift
            # Optional game slug follows (anything that isn't a flag)
            if [[ $# -gt 0 && "$1" != --* ]]; then
                GAME_SLUG="$1"
                shift
            fi
            ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            # Accept --no-rebuild anywhere in the argument list
            echo -e "${RED}Unknown argument: $1${NC}" >&2
            exit 1
            ;;
    esac
done

# ── Helpers ────────────────────────────────────────────────────────────────────

require_tool() {
    if ! command -v "$1" &>/dev/null; then
        echo -e "${RED}❌ '$1' not found. Install with: brew install $2${NC}" >&2
        exit 1
    fi
}

require_tool xcbeautify xcbeautify
require_tool xchtmlreport xctest-html-report

# arch=arm64 pins to a single destination — without it xcodebuild matches both
# arm64 and x86_64, launching two parallel test runners and doubling Wine installs.
ARCH="arm64"

# Unique result bundle path for this run so parallel runs don't collide
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_BUNDLE="$REPORTS_DIR/$TIMESTAMP.xcresult"
mkdir -p "$REPORTS_DIR"

open_html_report() {
    local xcresult="$1"
    if [[ -d "$xcresult" ]]; then
        echo -e "${BLUE}📊 Generating HTML report...${NC}"
        xchtmlreport --output "$REPORTS_DIR" "$xcresult"
        local html="$REPORTS_DIR/index.html"
        [[ -f "$html" ]] && open "$html"
    fi
}

# ── Build ──────────────────────────────────────────────────────────────────────

build_for_testing() {
    echo -e "${BLUE}🔨 Building for testing...${NC}"
    set -o pipefail
    NSUnbufferedIO=YES xcodebuild build-for-testing \
        -scheme SecondChance \
        -destination "platform=macOS,arch=$ARCH" \
        -derivedDataPath "$DERIVED_DATA" \
        2>&1 | xcbeautify --preserve-unbeautified
}

if [[ "$REBUILD" == true ]]; then
    build_for_testing
elif [[ ! -d "$DERIVED_DATA/Build/Products" ]]; then
    echo -e "${RED}❌ No previous build found. Run without --no-rebuild first.${NC}" >&2
    exit 1
fi

# ── Test runners ──────────────────────────────────────────────────────────────

run_unit_tests() {
    echo -e "${BLUE}🧪 Running unit tests...${NC}"
    set -o pipefail
    local exit_code=0
    NSUnbufferedIO=YES xcodebuild test-without-building \
        -scheme SecondChance \
        -destination "platform=macOS,arch=$ARCH" \
        -derivedDataPath "$DERIVED_DATA" \
        -resultBundlePath "$RESULT_BUNDLE" \
        -only-testing:SecondChanceTests/EventBusTests \
        -only-testing:SecondChanceTests/ContextualLoggerTests \
        -only-testing:SecondChanceTests/LogCorrelatorTests \
        -only-testing:SecondChanceTests/GameDetectorTests \
        -only-testing:SecondChanceTests/GameInstallerTests \
        2>&1 | xcbeautify --preserve-unbeautified || exit_code=$?
    open_html_report "$RESULT_BUNDLE"
    return $exit_code
}

run_integration_tests() {
    if [[ -n "$GAME_SLUG" ]]; then
        echo -e "${BLUE}🎮 Running integration tests for: $GAME_SLUG${NC}"
    else
        echo -e "${BLUE}🎮 Running integration tests for all games...${NC}"
    fi

    local env_prefix=""
    [[ -n "$GAME_SLUG" ]] && env_prefix="TEST_RUNNER_TEST_GAMES=$GAME_SLUG"
    [[ "$SKIP_BUILD" == true ]] && env_prefix="$env_prefix TEST_RUNNER_SKIP_BUILD=1"

    set -o pipefail
    local exit_code=0
    eval "NSUnbufferedIO=YES $env_prefix xcodebuild test-without-building \
        -scheme SecondChance \
        -destination 'platform=macOS,arch=$ARCH' \
        -derivedDataPath \"$DERIVED_DATA\" \
        -resultBundlePath \"$RESULT_BUNDLE\" \
        -parallel-testing-worker-count 1 \
        -only-testing:SecondChanceTests/DiskInstallIntegrationTests \
        2>&1 | xcbeautify --preserve-unbeautified" || exit_code=$?
    open_html_report "$RESULT_BUNDLE"
    return $exit_code
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "$COMMAND" in
    unit)
        run_unit_tests
        ;;
    integration)
        run_integration_tests
        ;;
    all)
        # Unit tests write to the same result bundle; integration appends a new run
        run_unit_tests
        echo ""
        RESULT_BUNDLE="$REPORTS_DIR/${TIMESTAMP}-integration.xcresult"
        run_integration_tests
        ;;
esac
