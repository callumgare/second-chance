#!/bin/bash
# run.sh - Run the SecondChance app or a built game wrapper
#
# Usage:
#   ./run.sh                        # Run app (build if not built)
#   ./run.sh --rebuild              # Force rebuild SecondChance app
#   ./run.sh --clear-wine-cache     # Clear cached Wine prefix
#   ./run.sh --game <slug>          # Build game wrapper (don't launch)
#   ./run.sh --game <slug> --rebuild-game  # Force rebuild game wrapper
#   ./run.sh --game <slug> --update-game   # Update WrappTemplate in existing game
#   ./run.sh --game <slug> --launch-game  # Build and launch game
#   ./run.sh --game <slug> --launch-game="arg1 arg2"  # Launch with arguments
#   ./run.sh --game seven-ships --launch-game=--wine-shell  # Launch wine shell in game
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
BUILD_SCRIPT="$SCRIPT_DIR/build.sh"
BUILD_GAME_SCRIPT="$SCRIPT_DIR/build-game.sh"
UPDATE_GAME_SCRIPT="$SCRIPT_DIR/update-game.sh"
BUILT_APPS_DIR="$SCRIPT_DIR/built-apps"

# Parse arguments
FORCE_REBUILD_APP=false
FORCE_REBUILD_GAME=false
UPDATE_GAME_FLAG=false
LAUNCH_GAME_FLAG=false
APP_ARGS=()
GAME_SLUG=""
DEBUG_FLAGS=()
OUTPUT_DIR="$BUILT_APPS_DIR"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild)
            FORCE_REBUILD_APP=true
            FORCE_REBUILD_GAME=true
            shift
            ;;
        --rebuild-game)
            FORCE_REBUILD_GAME=true
            shift
            ;;
        --update-game)
            UPDATE_GAME_FLAG=true
            shift
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
        --game)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo -e "${RED}Error: --game requires a game slug${NC}"
                exit 1
            fi
            GAME_SLUG="$2"
            shift 2
            ;;
        --output-dir)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo -e "${RED}Error: --output-dir requires a path${NC}"
                exit 1
            fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --launch-game=*)
            LAUNCH_GAME_FLAG=true
            # Extract value after = and split into array
            ARGS_STRING="${1#*=}"
            if [[ -n "$ARGS_STRING" ]]; then
                # Split the string into array by spaces
                read -ra APP_ARGS <<< "$ARGS_STRING"
            fi
            shift
            ;;
        --launch-game)
            LAUNCH_GAME_FLAG=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--rebuild] [--skip-installer] [--clear-wine-cache] [--output-dir <path>] [--game <slug> [--rebuild-game|--update-game] [--launch-game[=\"ARG...\"]]]]"
            exit 1
            ;;
    esac
done

# Validate flag combinations
if [[ "$LAUNCH_GAME_FLAG" == true && -z "$GAME_SLUG" ]]; then
    echo -e "${RED}Error: --launch-game can only be used with --game${NC}"
    exit 1
fi

if [[ "$UPDATE_GAME_FLAG" == true && -z "$GAME_SLUG" ]]; then
    echo -e "${RED}Error: --update-game requires --game${NC}"
    exit 1
fi

if [[ "$UPDATE_GAME_FLAG" == true && "$FORCE_REBUILD_APP" == true ]]; then
    echo -e "${RED}Error: --update-game cannot be used with --rebuild${NC}"
    exit 1
fi

if [[ "$UPDATE_GAME_FLAG" == true && "$FORCE_REBUILD_GAME" == true ]]; then
    echo -e "${RED}Error: --update-game cannot be used with --rebuild-game${NC}"
    exit 1
fi

# Function to build SecondChance app if needed
build_app_if_needed() {
    local force_rebuild=$1
    
    if [[ ! -d "$APP_PATH" ]] || [[ "$force_rebuild" == true ]]; then
        if [[ "$force_rebuild" == true ]]; then
            echo -e "${BLUE}🔄 Rebuilding SecondChance app...${NC}"
        else
            echo -e "${BLUE}🔨 SecondChance app not found, building...${NC}"
        fi
        BUILD_LOG="$SCRIPT_DIR/DerivedData/build-log-$(date +%Y%m%d-%H%M%S).txt"
        mkdir -p "$(dirname "$BUILD_LOG")"
        
        "$BUILD_SCRIPT"
    fi
}

# Function to launch game if --launch-game flag is set
launch_game_if_requested() {
    local game_app_path=$1
    
    if [[ "$LAUNCH_GAME_FLAG" == true ]]; then
        echo -e "${BLUE}🎮 Launching game: $(basename "$game_app_path" .app)${NC}"
        # Exec the binary directly so the game's stdio (and thus the
        # WrappTemplate's stderr log stream) reaches this terminal.
        if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
            echo -e "${BLUE}   Arguments: ${APP_ARGS[*]}${NC}"
            "$game_app_path/Contents/MacOS/WrappTemplate" "${APP_ARGS[@]}"
        else
            "$game_app_path/Contents/MacOS/WrappTemplate"
        fi
    fi
}

# If launching a game, find and run it
if [[ -n "$GAME_SLUG" ]]; then
    # Source the game info helper
    source "$SCRIPT_DIR/lib/game-info.sh"
    
    # Get the game app path
    GAME_APP_NAME=$(get_game_app_name "$GAME_SLUG")
    if [[ -z "$GAME_APP_NAME" ]]; then
        echo -e "${RED}Error: Could not find game title for slug '$GAME_SLUG'${NC}"
        exit 1
    fi
    GAME_APP_PATH="$OUTPUT_DIR/$GAME_APP_NAME.app"
    
    # Handle --update-game flag
    if [[ "$UPDATE_GAME_FLAG" == true ]]; then
        # Build update-game.sh arguments
        UPDATE_ARGS=("$GAME_SLUG")
        UPDATE_ARGS+=("--built-app-path" "$GAME_APP_PATH")
        
        if [[ "$LAUNCH_GAME_FLAG" == true ]]; then
            UPDATE_ARGS+=("--launch")
            if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
                UPDATE_ARGS+=("--launch-args" "${APP_ARGS[*]}")
            fi
        fi
        
        "$UPDATE_GAME_SCRIPT" "${UPDATE_ARGS[@]}"
        exit 0
    fi
    
    # Build or rebuild the game if needed
    if [[ ! -f "$GAME_APP_PATH/Contents/Info.plist" || "$FORCE_REBUILD_GAME" == true ]]; then
        # Need to build SecondChance first if it doesn't exist or rebuild requested
        build_app_if_needed "$FORCE_REBUILD_APP"
        
        if [[ "$FORCE_REBUILD_GAME" == true && -d "$GAME_APP_PATH" ]]; then
            echo -e "${BLUE}🔄 Rebuilding game wrapper for '$GAME_SLUG'...${NC}"
            rm -rf "$GAME_APP_PATH"
        elif [[ ! -f "$GAME_APP_PATH/Contents/Info.plist" ]]; then
            echo -e "${BLUE}🔨 Game wrapper not found for '$GAME_SLUG', building...${NC}"
        fi
        
        # Build build-game.sh arguments
        BUILD_ARGS=("$GAME_SLUG")
        BUILD_ARGS+=("--output-dir" "$OUTPUT_DIR")
        
        if [[ ${#DEBUG_FLAGS[@]} -gt 0 ]]; then
            BUILD_ARGS+=("${DEBUG_FLAGS[@]}")
        fi
        
        if [[ "$LAUNCH_GAME_FLAG" == true ]]; then
            BUILD_ARGS+=("--launch")
            if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
                BUILD_ARGS+=("--launch-args" "${APP_ARGS[*]}")
            fi
        fi
        
        "$BUILD_GAME_SCRIPT" "${BUILD_ARGS[@]}"
    else
        echo -e "${GREEN}✅ Using existing game wrapper: $(basename "$GAME_APP_PATH" .app)${NC}"
        
        # If launch flag provided but not rebuilding, launch manually
        launch_game_if_requested "$GAME_APP_PATH"
    fi
    exit 0
fi

# Build if needed
build_app_if_needed "$FORCE_REBUILD_APP"

# Run the app — binary directly, not `open`, so stdio stays attached to
# this terminal and the app's stderr log stream works from the first line.
echo -e "${BLUE}🚀 Running Second Chance...${NC}"
if [[ " ${DEBUG_FLAGS[*]} " == *" --debug "* ]]; then
    echo -e "${BLUE}   Debug mode enabled${NC}"
fi
"$APP_PATH/Contents/MacOS/Second Chance" "${DEBUG_FLAGS[@]}"

echo -e "${GREEN}✅ Second Chance quit${NC}"
