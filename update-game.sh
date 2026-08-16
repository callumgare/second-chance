#!/bin/bash
# update-game.sh - Update GameWrapper in an existing Nancy Drew game wrapper
#
# Usage:
#   ./update-game.sh <game-slug> [options]
#
# Options:
#   --built-app-path <path>    Path to the built game app (default: ./built-apps/Nancy Drew - <title>.app)
#   --launch                   Launch the game after updating
#   --launch-args "arg1 arg2"  Arguments to pass when launching
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILT_APPS_DIR="$SCRIPT_DIR/built-apps"

# Parse arguments
GAME_SLUG=""
BUILT_APP_PATH=""
LAUNCH_GAME_FLAG=false
APP_ARGS=()

# First positional argument is the game slug
if [[ $# -gt 0 && "$1" != --* ]]; then
    GAME_SLUG="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --built-app-path)
            BUILT_APP_PATH="$2"
            shift 2
            ;;
        --launch)
            LAUNCH_GAME_FLAG=true
            shift
            ;;
        --launch-args)
            read -ra APP_ARGS <<< "$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$GAME_SLUG" ]]; then
    echo -e "${RED}Error: Game slug is required${NC}"
    echo "Usage: $0 <game-slug> [options]"
    exit 1
fi

# Source the game info helper
source "$SCRIPT_DIR/lib/game-info.sh"

# Get the full app name from the slug
GAME_TITLE=$(get_game_title "$GAME_SLUG")
if [[ -z "$GAME_TITLE" ]]; then
    echo -e "${RED}Error: Unknown game: $GAME_SLUG${NC}"
    exit 1
fi

# Use provided path or default
if [[ -z "$BUILT_APP_PATH" ]]; then
    BUILT_APP_PATH=$(get_default_game_app_path "$GAME_SLUG")
fi

if [[ ! -d "$BUILT_APP_PATH" ]]; then
    echo -e "${RED}Error: Built app not found at $BUILT_APP_PATH${NC}"
    echo -e "${YELLOW}You need to build the game first with: ./run.sh --game $GAME_SLUG${NC}"
    exit 1
fi

echo -e "${BLUE}🔨 Building...${NC}"
"$SCRIPT_DIR/build.sh"

echo -e "${BLUE}📦 Copying updated wrapper to $(basename "$BUILT_APP_PATH")...${NC}"

# Verify the built wrapper exists
BUILT_WRAPPER="./DerivedData/Build/Products/Debug/GameWrapper.app/Contents/MacOS/GameWrapper"
BUILT_DYLIB="./DerivedData/Build/Products/Debug/GameWrapper.app/Contents/MacOS/GameWrapper.debug.dylib"
if [[ ! -f "$BUILT_WRAPPER" ]]; then
    echo -e "${RED}Error: Built wrapper not found at $BUILT_WRAPPER${NC}"
    exit 1
fi
if [[ ! -f "$BUILT_DYLIB" ]]; then
    echo -e "${RED}Error: Built dylib not found at $BUILT_DYLIB${NC}"
    exit 1
fi

# Copy both the stub executable and the debug dylib
if ! cp -f "$BUILT_WRAPPER" "$BUILT_APP_PATH/Contents/MacOS/GameWrapper"; then
    echo -e "${RED}❌ Failed to copy wrapper executable${NC}"
    exit 1
fi

if ! cp -f "$BUILT_DYLIB" "$BUILT_APP_PATH/Contents/MacOS/GameWrapper.debug.dylib"; then
    echo -e "${RED}❌ Failed to copy dylib${NC}"
    exit 1
fi

# Code sign the copied executables (ad-hoc signature for local development)
echo -e "${BLUE}🔐 Code signing the wrapper...${NC}"
if ! codesign --force --sign - "$BUILT_APP_PATH/Contents/MacOS/GameWrapper"; then
    echo -e "${RED}❌ Failed to code sign wrapper executable${NC}"
    exit 1
fi

if ! codesign --force --sign - "$BUILT_APP_PATH/Contents/MacOS/GameWrapper.debug.dylib"; then
    echo -e "${RED}❌ Failed to code sign dylib${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Wrapper updated successfully!${NC}"

# Launch game if requested
if [[ "$LAUNCH_GAME_FLAG" == true ]]; then
    echo -e "${BLUE}🎮 Launching game: $(basename "$BUILT_APP_PATH" .app)${NC}"
    # Exec the binary directly so the game's stdio (and thus the
    # GameWrapper's stderr log stream) reaches this terminal.
    if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
        echo -e "${BLUE}   Arguments: ${APP_ARGS[*]}${NC}"
        "$BUILT_APP_PATH/Contents/MacOS/GameWrapper" "${APP_ARGS[@]}"
    else
        "$BUILT_APP_PATH/Contents/MacOS/GameWrapper"
    fi
else
    echo -e "${BLUE}You can now run: open '$BUILT_APP_PATH'${NC}"
fi
