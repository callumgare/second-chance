#!/bin/bash
# run.sh - Run the SecondChance app or a built game wrapper
#
# Usage:
#   ./run.sh                        # Run app (build if not built)
#   ./run.sh --rebuild              # Force rebuild SecondChance app
#   ./run.sh --game <slug>          # Build game wrapper (don't launch)
#   ./run.sh --game <slug> --rebuild-game  # Force rebuild game wrapper
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
APP_PATH="$SCRIPT_DIR/DerivedData/Build/Products/Debug/SecondChance.app"
BUILD_SCRIPT="$SCRIPT_DIR/build.sh"
BUILT_APPS_DIR="$SCRIPT_DIR/built-apps"

# Parse arguments
FORCE_REBUILD_APP=false
FORCE_REBUILD_GAME=false
LAUNCH_GAME_FLAG=false
APP_ARGS=()
GAME_SLUG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild)
            FORCE_REBUILD_APP=true
            shift
            ;;
        --rebuild-game)
            FORCE_REBUILD_GAME=true
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
            echo "Usage: $0 [--rebuild] [--game <slug> [--rebuild-game] [--launch-game[=\"ARG...\"]]]"
            exit 1
            ;;
    esac
done

# Validate that --launch-game requires --game
if [[ "$LAUNCH_GAME_FLAG" == true && -z "$GAME_SLUG" ]]; then
    echo -e "${RED}Error: --launch-game can only be used with --game${NC}"
    exit 1
fi

# If launching a game, find and run it
if [[ -n "$GAME_SLUG" ]]; then
    # Get the game title from GameInfoProvider.swift
    GAME_INFO_FILE="$SCRIPT_DIR/SecondChance/Services/GameInfoProvider.swift"
    GAME_TITLE=$(awk -v slug="$GAME_SLUG" '
        /GameInfo\(/ { in_game_info=1; found_slug=0; title="" }
        in_game_info && /id:/ && $0 ~ slug { found_slug=1 }
        in_game_info && found_slug && /title:/ {
            # Extract title between quotes
            n = split($0, parts, "\"")
            if (n >= 2) title = parts[2]
        }
        in_game_info && /\)/ {
            if (found_slug && title != "") {
                print title
                exit
            }
            in_game_info=0
        }
    ' "$GAME_INFO_FILE")
    
    if [[ -z "$GAME_TITLE" ]]; then
        echo -e "${RED}Error: Could not find game title for slug '$GAME_SLUG' in GameInfoProvider.swift${NC}"
        exit 1
    fi
    
    # Search for the game in built-apps using the actual title
    GAME_APP="$BUILT_APPS_DIR/Nancy Drew - $GAME_TITLE.app"
    
    # Build or rebuild the game if needed
    if [[ ! -f "$GAME_APP/Contents/Info.plist" || "$FORCE_REBUILD_GAME" == true ]]; then
        # Need to build SecondChance first if it doesn't exist or rebuild requested
        if [[ ! -d "$APP_PATH" ]] || [[ "$FORCE_REBUILD_APP" == true ]]; then
            if [[ "$FORCE_REBUILD_APP" == true ]]; then
                echo -e "${BLUE}🔄 Rebuilding SecondChance app...${NC}"
            else
                echo -e "${BLUE}🔨 SecondChance app not found, building...${NC}"
            fi
            "$BUILD_SCRIPT" --quiet
        fi
        
        if [[ "$FORCE_REBUILD_GAME" == true && -n "$GAME_APP" ]]; then
            echo -e "${BLUE}🔄 Rebuilding game wrapper for '$GAME_SLUG'...${NC}"
            rm -rf "$GAME_APP"
        elif [[ -z "$GAME_APP" ]]; then
            echo -e "${BLUE}🔨 Game wrapper not found for '$GAME_SLUG', building...${NC}"
        fi
        
        # Find installer directory
        INSTALLER_DIR="$SCRIPT_DIR/installers/$GAME_SLUG"
        if [[ ! -d "$INSTALLER_DIR" ]]; then
            echo -e "${RED}Error: Installer directory not found: $INSTALLER_DIR${NC}"
            echo -e "${YELLOW}Available installers with disk-1.iso:${NC}"
            for dir in "$SCRIPT_DIR/installers"/*; do
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
        
        # Export environment variables for SecondChance
        export NON_INTERACTIVE=true
        export INSTALLATION_SOURCE=disk
        export OUTPUT_PATH="$BUILT_APPS_DIR"
        export DISK_1_PATH="$DISK_1_ISO"
        
        if [[ -f "$DISK_2_ISO" ]]; then
            export DISK_2_PATH="$DISK_2_ISO"
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
        echo -e "${BLUE}                OUTPUT_PATH=$OUTPUT_PATH${NC}"
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
        
        "$APP_PATH/Contents/MacOS/SecondChance"
        
        # Check if the wrapper was created
        if [[ ! -f "$GAME_APP/Contents/Info.plist" ]]; then
            echo -e "${RED}Error: Failed to build game wrapper for '$GAME_SLUG'${NC}"
            echo -e "${YELLOW}Expected location: $GAME_APP${NC}"
            echo -e "${YELLOW}Checking what was created:${NC}"
            ls -la "$BUILT_APPS_DIR/" 2>/dev/null || echo "  (directory is empty or doesn't exist)"
            exit 1
        fi
        
        echo -e "${GREEN}✅ Game wrapper created: $(basename "$GAME_APP" .app)${NC}"
    else
        echo -e "${GREEN}✅ Using existing game wrapper: $(basename "$GAME_APP" .app)${NC}"
        
        # If launch flag provided but not rebuilding, launch manually
        if [[ "$LAUNCH_GAME_FLAG" == true ]]; then
            echo -e "${BLUE}🎮 Launching game: $(basename "$GAME_APP" .app)${NC}"
            if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
                echo -e "${BLUE}   Arguments: ${APP_ARGS[*]}${NC}"
            fi
            # Find the actual executable (not .dylib files)
            GAME_EXECUTABLE=$(find "$GAME_APP/Contents/MacOS" -type f -perm +111 ! -name "*.dylib" | head -1)
            if [[ -z "$GAME_EXECUTABLE" ]]; then
                echo -e "${RED}Error: Could not find executable in $GAME_APP/Contents/MacOS${NC}"
                exit 1
            fi
            "$GAME_EXECUTABLE" "${APP_ARGS[@]}"
        fi
    fi
    exit 0
fi

# Build if needed
if [[ ! -d "$APP_PATH" ]] || [[ "$FORCE_REBUILD_APP" == true ]]; then
    if [[ "$FORCE_REBUILD_APP" == true ]]; then
        echo -e "${BLUE}🔄 Rebuilding app...${NC}"
    else
        echo -e "${BLUE}🔨 App not found, building...${NC}"
    fi
    "$BUILD_SCRIPT" --quiet
else
    echo -e "${BLUE}✅ Using existing build${NC}"
fi

# Run the app
echo -e "${BLUE}🚀 Running SecondChance...${NC}"
open "$APP_PATH"
