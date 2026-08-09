#!/bin/bash
# test-game.sh - Wrapper script for GameTester with auto-compilation
#
# This script automatically rebuilds GameTester when source files change,
# and can accept either a game slug or a direct path to a game app.
#
# Usage:
#   ./test-game.sh <game-slug-or-path> [--timeout <seconds>] [--debug] [--log <path>]
#
# Examples:
#   ./test-game.sh old-clock
#   ./test-game.sh old-clock --timeout 90
#   ./test-game.sh "built-apps/Nancy Drew - Secret of the Old Clock.app"
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME_TESTER_EXECUTABLE="$SCRIPT_DIR/GameTester"
BUILD_SCRIPT="$SCRIPT_DIR/build.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the game info helper
source "$REPO_ROOT/lib/game-info.sh"

# Print usage
print_usage() {
    cat << EOF
test-game.sh - Run GameTester with automatic compilation

Usage:
  ./test-game.sh <game-slug-or-path> [options]

Arguments:
  game-slug-or-path    Either a game slug (e.g., 'old-clock') or a path to a game app

Options:
  --timeout <seconds>  Maximum runtime (default: 60)
  --debug              Launch game in debug mode
  --log <path>         Path to write game wrapper log output
  --help, -h           Show this help message

Examples:
  ./test-game.sh old-clock
  ./test-game.sh old-clock --timeout 90
  ./test-game.sh "built-apps/Nancy Drew - Secret of the Old Clock.app"
  ./test-game.sh scarlet-hand --debug --log /tmp/wrapper.log

EOF
}

# Parse arguments
if [[ $# -eq 0 ]]; then
    print_usage
    exit 1
fi

GAME_SLUG_OR_PATH=""
GAME_TESTER_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            print_usage
            exit 0
            ;;
        --timeout|--debug|--log)
            GAME_TESTER_ARGS+=("$1")
            if [[ "$1" == "--timeout" || "$1" == "--log" ]]; then
                shift
                if [[ $# -gt 0 ]]; then
                    GAME_TESTER_ARGS+=("$1")
                fi
            fi
            shift
            ;;
        -*)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            echo ""
            print_usage
            exit 1
            ;;
        *)
            if [[ -z "$GAME_SLUG_OR_PATH" ]]; then
                GAME_SLUG_OR_PATH="$1"
            else
                echo -e "${RED}Error: Multiple game arguments provided${NC}"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$GAME_SLUG_OR_PATH" ]]; then
    echo -e "${RED}Error: No game slug or path provided${NC}"
    echo ""
    print_usage
    exit 1
fi

# Determine if input is a slug or path
GAME_APP_PATH=""

if [[ -d "$GAME_SLUG_OR_PATH" ]]; then
    # It's a directory path - use it directly
    GAME_APP_PATH="$GAME_SLUG_OR_PATH"
elif [[ "$GAME_SLUG_OR_PATH" == *".app"* || "$GAME_SLUG_OR_PATH" == *"/"* ]]; then
    # Looks like a path but doesn't exist
    echo -e "${RED}Error: Game app path does not exist: $GAME_SLUG_OR_PATH${NC}"
    exit 1
else
    # Treat as a slug
    echo -e "${BLUE}🔍 Resolving game slug: $GAME_SLUG_OR_PATH${NC}"
    GAME_APP_PATH=$(get_default_game_app_path "$GAME_SLUG_OR_PATH")
    
    if [[ -z "$GAME_APP_PATH" ]]; then
        echo -e "${RED}Error: Could not resolve game slug: $GAME_SLUG_OR_PATH${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Resolved to: $GAME_APP_PATH${NC}"
fi

# Verify the game app exists
if [[ ! -d "$GAME_APP_PATH" ]]; then
    echo -e "${RED}Error: Game app does not exist: $GAME_APP_PATH${NC}"
    echo -e "${YELLOW}Hint: You may need to build it first with ./build-game.sh${NC}"
    exit 1
fi

# Build GameTester if needed
if ! "$BUILD_SCRIPT"; then
    exit 1
fi

# Run GameTester
echo ""
echo -e "${BLUE}🚀 Running GameTester on: $(basename "$GAME_APP_PATH")${NC}"
echo ""

exec "$GAME_TESTER_EXECUTABLE" "$GAME_APP_PATH" "${GAME_TESTER_ARGS[@]}"
