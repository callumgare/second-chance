#!/bin/bash
# build-game.sh - Build a Nancy Drew game wrapper
#
# Usage:
#   ./build-game.sh <game-slug> [options]
#
# Options:
#   --output-dir <path>         Directory to save the built app (default: ./built-apps)
#   --skip-installer            Skip installer (debug flag)
#   --clear-wine-cache         Clear Wine cache (debug flag)
#   --debug                    Enable debug mode (shows log window in SecondChance)
#   --launch                   Launch the game after building
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
APP_PATH="$SCRIPT_DIR/DerivedData/Build/Products/Debug/Second Chance.app"
BUILT_APPS_DIR="$SCRIPT_DIR/built-apps"

# Parse arguments
GAME_SLUG=""
OUTPUT_DIR=""
DEBUG_FLAGS=()
LAUNCH_GAME_FLAG=false
APP_ARGS=()

# First positional argument is the game slug
if [[ $# -gt 0 && "$1" != --* ]]; then
    GAME_SLUG="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --skip-installer)
            DEBUG_FLAGS+=("--skip-installer")
            shift
            ;;
        --clear-wine-cache)
            DEBUG_FLAGS+=("--clear-wine-cache")
            shift
            ;;
        --debug)
            DEBUG_FLAGS+=("--debug")
            shift
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
            echo ""
            echo "Usage: $0 <game-slug> [options]"
            echo ""
            echo "Options:"
            echo "  --output-dir <path>         Directory to save the built app (default: ./built-apps)"
            echo "  --skip-installer            Skip installer (debug flag)"
            echo "  --clear-wine-cache          Clear Wine cache (debug flag)"
            echo "  --debug                     Enable debug mode (shows log window in SecondChance)"
            echo "  --launch                    Launch the game after building"
            echo "  --launch-args \"arg1 arg2\"   Arguments to pass when launching"
            exit 1
            ;;
    esac
done

if [[ -z "$GAME_SLUG" ]]; then
    echo -e "${RED}Error: Game slug is required${NC}"
    echo "Usage: $0 <game-slug> [options]"
    exit 1
fi

# Use provided output path or default
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$BUILT_APPS_DIR"
fi

# Source the game info helper
source "$SCRIPT_DIR/lib/game-info.sh"

# Get the game title from the slug
GAME_TITLE=$(get_game_title "$GAME_SLUG")
if [[ -z "$GAME_TITLE" ]]; then
    echo -e "${RED}Error: Could not find game title for slug '$GAME_SLUG'${NC}"
    exit 1
fi

# Use custom output path or get the title-based name
if [[ "$OUTPUT_DIR" == "$BUILT_APPS_DIR" ]]; then
    GAME_APP=$(get_default_game_app_path "$GAME_SLUG")
else
    GAME_APP="$OUTPUT_DIR/Nancy Drew - $GAME_TITLE.app"
fi

# Check if SecondChance app exists
if [[ ! -d "$APP_PATH" ]]; then
    echo -e "${RED}Error: SecondChance app not found at $APP_PATH${NC}"
    echo -e "${YELLOW}Run ./build.sh first${NC}"
    exit 1
fi

# Find installer directory (allow override via env var)
INSTALLERS_DIR="${INSTALLERS_DIR:-$SCRIPT_DIR/installers}"
INSTALLER_DIR="$INSTALLERS_DIR/$GAME_SLUG"
if [[ ! -d "$INSTALLER_DIR" ]]; then
    echo -e "${RED}Error: Installer directory not found: $INSTALLER_DIR${NC}"
    echo -e "${YELLOW}Available installers with disk-1.iso:${NC}"
    for dir in "$INSTALLERS_DIR"/*; do
        if [[ -d "$dir" && -f "$dir/disk-1.iso" ]]; then
            basename "$dir"
        fi
    done | head -20
    exit 1
fi

# Find disk ISOs
DISK_1_ISO="$INSTALLER_DIR/disk-1.iso"
DISK_2_ISO="$INSTALLER_DIR/disk-2.iso"

if [[ ! -f "$DISK_1_ISO" ]]; then
    echo -e "${RED}Error: disk-1.iso not found in $INSTALLER_DIR${NC}"
    exit 1
fi

# Pass ISO paths directly - Swift code will handle mounting
DISK_1_PATH="$DISK_1_ISO"

if [[ -f "$DISK_2_ISO" ]]; then
    DISK_2_PATH="$DISK_2_ISO"
fi

# Export environment variables for SecondChance
export NON_INTERACTIVE=true
export INSTALLATION_SOURCE=disk
export OUTPUT_PATH="$OUTPUT_DIR"
export DISK_1_PATH="$DISK_1_PATH"

if [[ -n "${DISK_2_PATH:-}" ]]; then
    export DISK_2_PATH="$DISK_2_PATH"
fi

if [[ "$LAUNCH_GAME_FLAG" == true ]]; then
    export LAUNCH_GAME=true
    if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
        export LAUNCH_GAME_ARGS="${APP_ARGS[*]}"
    fi
fi

# Display environment configuration
echo -e "${BLUE}📦 Building game wrapper from $INSTALLER_DIR...${NC}"
echo -e "${BLUE}   Environment: NON_INTERACTIVE=true${NC}"
echo -e "${BLUE}                INSTALLATION_SOURCE=$INSTALLATION_SOURCE${NC}"
echo -e "${BLUE}                OUTPUT_PATH=$OUTPUT_DIR${NC}"
echo -e "${BLUE}                DISK_1_PATH=$DISK_1_PATH${NC}"
if [[ -n "${DISK_2_PATH:-}" ]]; then
    echo -e "${BLUE}                DISK_2_PATH=$DISK_2_PATH${NC}"
fi
if [[ -n "${LAUNCH_GAME:-}" ]]; then
    echo -e "${BLUE}                LAUNCH_GAME=$LAUNCH_GAME${NC}"
    if [[ -n "${LAUNCH_GAME_ARGS:-}" ]]; then
        echo -e "${BLUE}                LAUNCH_GAME_ARGS=$LAUNCH_GAME_ARGS${NC}"
    fi
fi
if [[ ${#DEBUG_FLAGS[@]} -gt 0 ]]; then
    echo -e "${BLUE}                Debug flags: ${DEBUG_FLAGS[*]}${NC}"
fi

# Run SecondChance and capture exit code
"$APP_PATH/Contents/MacOS/Second Chance" "${DEBUG_FLAGS[@]}"
EXIT_CODE=$?

if [[ "$EXIT_CODE" -ne 0 ]]; then
    echo -e "${RED}❌ SecondChance exited with error code $EXIT_CODE${NC}"
    exit "$EXIT_CODE"
fi

# Check if the wrapper was created
if [[ ! -f "$GAME_APP/Contents/Info.plist" ]]; then
    echo -e "${RED}Error: Failed to build game wrapper for '$GAME_SLUG'${NC}"
    echo -e "${YELLOW}Expected location: $GAME_APP${NC}"
    echo -e "${YELLOW}Checking what was created:${NC}"
    ls -la "$OUTPUT_DIR/" 2>/dev/null || echo "  (directory is empty or doesn't exist)"
    exit 1
fi

echo -e "${GREEN}✅ Game wrapper created: $(basename "$GAME_APP" .app)${NC}"
