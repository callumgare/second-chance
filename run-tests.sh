#!/bin/bash
# run-tests.sh - Second Chance test runner
#
# Usage:
#   ./run-tests.sh [--no-rebuild] [--raw-logs | --quiet] [command] [game-slug]
#
# Commands:
#   (none)              Rebuild and run all tests
#   unit | u            Run unit tests only
#   integration | i     Run integration tests (all games, or one if slug given)
#
# Options:
#   --raw-logs          Show raw xcodebuild output instead of xcbeautify
#   --quiet             Suppress all build/test output
#   --no-rebuild        Skip the build step (use existing build)
#   --test-existing-wrapper  Skip install, launch prebuilt wrapper from built-apps/
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
RAW_LOGS=false
QUIET=false

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
        --raw-logs)
            RAW_LOGS=true
            shift
            ;;
        --quiet|-q)
            QUIET=true
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

if [[ "$QUIET" == true && "$RAW_LOGS" == true ]]; then
    echo -e "${RED}❌ --quiet and --raw-logs are mutually exclusive${NC}" >&2
    exit 1
fi

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
# Build the pipe suffix for xcodebuild output based on flags.
if [[ "$QUIET" == true ]]; then
    XCBEAUTIFY_OPTIONS="--quiet --disable-logging"
elif [[ "$RAW_LOGS" == true ]]; then
    XCBEAUTIFY_OPTIONS="--preserve-unbeautified"
else
    XCBEAUTIFY_OPTIONS=""
fi

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
        2>&1 | xcbeautify $XCBEAUTIFY_OPTIONS
}

if [[ "$REBUILD" == true ]]; then
    build_for_testing
elif [[ ! -d "$DERIVED_DATA/Build/Products" ]]; then
    echo -e "${RED}❌ No previous build found. Run without --no-rebuild first.${NC}" >&2
    exit 1
fi

# ── Test runner ───────────────────────────────────────────────────────────────

run_tests() {
    local test_type="$1"

    local extra_args=()
    local extra_env=()

    case "$test_type" in
        unit)
            echo -e "${BLUE}🧪 Running unit tests...${NC}"
            extra_args+=(
                -only-testing:SecondChanceTests/EventBusTests
                -only-testing:SecondChanceTests/LogStoreTests
                -only-testing:SecondChanceTests/LogWindowTests
                -only-testing:SecondChanceTests/GameDetectorTests
                -only-testing:SecondChanceTests/GameInstallerTests
                -only-testing:SecondChanceTests/ErrorViewTests
            )
            ;;
        integration)
            if [[ -n "$GAME_SLUG" ]]; then
                echo -e "${BLUE}🎮 Running integration tests for: $GAME_SLUG${NC}"
                extra_env+=(TEST_RUNNER_TEST_GAMES="$GAME_SLUG")
            else
                echo -e "${BLUE}🎮 Running integration tests for all games...${NC}"
            fi
            [[ "$SKIP_BUILD" == true ]] && extra_env+=(TEST_RUNNER_SKIP_BUILD=1)
            extra_args+=(
                -parallel-testing-worker-count 1
                -only-testing:SecondChanceTests/DiskInstallIntegrationTests
            )
            ;;
        all)
            echo -e "${BLUE}🧪 Running all tests...${NC}"
            ;;
    esac

    set -o pipefail
    local exit_code=0
    env NSUnbufferedIO=YES ${extra_env[@]+"${extra_env[@]}"} xcodebuild test-without-building \
        -scheme SecondChance \
        -destination "platform=macOS,arch=$ARCH" \
        -derivedDataPath "$DERIVED_DATA" \
        -resultBundlePath "$RESULT_BUNDLE" \
        ${extra_args[@]+"${extra_args[@]}"} \
        2>&1 | xcbeautify $XCBEAUTIFY_OPTIONS || exit_code=$?
    open_html_report "$RESULT_BUNDLE"
    return $exit_code
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

run_tests "$COMMAND"
