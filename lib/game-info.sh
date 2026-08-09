#!/bin/bash
# game-info.sh - Helper functions to extract game information from GameInfoProvider.swift
#
# This script provides functions to query game metadata from the Swift source code.
# It replaces the old game-titles-info.sh from the bash implementation.

# Get the script's directory to locate GameInfoProvider.swift
GAME_INFO_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME_INFO_FILE="$GAME_INFO_SCRIPT_DIR/SecondChance/Services/GameInfoProvider.swift"

# Verify GameInfoProvider.swift exists
if [[ ! -f "$GAME_INFO_FILE" ]]; then
    echo "ERROR: GameInfoProvider.swift not found at: $GAME_INFO_FILE" >&2
    exit 1
fi

# Get game title from slug
# Usage: get_game_title <game-slug>
# Returns: Game title (e.g., "Last Train to Blue Moon Canyon")
get_game_title() {
    local game_slug="$1"
    
    if [[ -z "$game_slug" ]]; then
        echo "ERROR: get_game_title requires a game slug argument" >&2
        return 1
    fi
    
    local title
    title=$(awk -v slug="$game_slug" '
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
    
    if [[ -z "$title" ]]; then
        echo "ERROR: Could not find game title for slug '$game_slug' in GameInfoProvider.swift" >&2
        return 1
    fi
    
    echo "$title"
    return 0
}

# Get all game IDs from GameInfoProvider.swift
# Usage: get_all_game_ids
# Returns: Array of game IDs (one per line)
get_all_game_ids() {
    local game_ids=()
    
    # Extract game IDs in order
    # The pattern matches lines like: id: "secrets-can-kill",
    while IFS= read -r line; do
        if [[ $line =~ id:[[:space:]]*\"([^\"]+)\" ]]; then
            game_ids+=("${BASH_REMATCH[1]}")
        fi
    done < "$GAME_INFO_FILE"
    
    # Check if we found any games
    if [ ${#game_ids[@]} -eq 0 ]; then
        echo "ERROR: No game IDs found in GameInfoProvider.swift" >&2
        return 1
    fi
    
    # Output the game IDs (one per line)
    printf '%s\n' "${game_ids[@]}"
    return 0
}

# Get full app name for a game slug
# Usage: get_game_app_name <game-slug>
# Returns: Full app name (e.g., "Nancy Drew - Last Train to Blue Moon Canyon")
get_game_app_name() {
    local game_slug="$1"
    local title
    
    title=$(get_game_title "$game_slug") || return 1
    echo "Nancy Drew - $title"
    return 0
}

# Get default built-apps path for a game slug
# Usage: get_default_game_app_path <game-slug>
# Returns: Full path to the game app in built-apps directory
get_default_game_app_path() {
    local game_slug="$1"
    local app_name
    local built_apps_dir="$GAME_INFO_SCRIPT_DIR/built-apps"
    
    app_name=$(get_game_app_name "$game_slug") || return 1
    echo "$built_apps_dir/$app_name.app"
    return 0
}
