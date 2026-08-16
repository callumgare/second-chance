#!/bin/bash
set -euo pipefail

# This script downloads and caches game-specific patches for SecondChance
# Patches are cached per-game to avoid re-downloading during rebuilds
# Downloaded patches are also copied into the app bundle for use at install time

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Base cache directory
CACHE_DIR="${HOME}/Library/Caches/SecondChance"
PATCHES_CACHE="${CACHE_DIR}/game-patches"

# Destination in app bundle
PATCHES_DEST="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/game-patches"

echo "🔍 Setting up game patches for SecondChance..."

# Function to get game data
#   - Call with "list" to get all game IDs
#   - Call with <game-id> to get patch URLs for that game
get_game_data() {
    case "$1" in
        "list")
            echo "castle-malloy stay-tuned"
            ;;
        "stay-tuned")
            echo "https://www.herinteractive.com/wp-content/uploads/stfd-cabinet.zip https://www.herinteractive.com/wp-content/uploads/timepatch.zip"
            ;;
        "castle-malloy")
            echo "https://www.herinteractive.com/wp-content/uploads/HAU-1.1-patch1.zip"
            ;;
        # Add more games here:
        # "your-game-id")
        #     echo "https://example.com/patch1.zip https://example.com/patch2.exe"
        #     ;;
    esac
}

# Get list of games with patches
GAME_IDS=$(get_game_data "list")

# Check if any patches are defined
if [ -z "$GAME_IDS" ]; then
    echo "ℹ️  No patches defined"
    echo "   Add entries to the get_patch_urls() function."
    exit 0
fi

# Loop through all games
for game_id in $GAME_IDS; do
    # Convert game ID to slug-like format if needed
    GAME_SLUG=$(echo "$game_id" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    
    # Get patch URLs for this game
    PATCH_URLS=$(get_game_data "$game_id")
    
    # Skip if no URLs defined
    if [ -z "$PATCH_URLS" ]; then
        echo "ℹ️  No patches defined for '${game_id}'"
        echo ""
        continue
    fi
    
    # Game-specific cache directory
    GAME_PATCH_DIR="${PATCHES_CACHE}/${GAME_SLUG}"
    
    # Create cache directory if needed
    mkdir -p "${GAME_PATCH_DIR}"
    
    echo "🎮 Game: ${game_id}"
    echo "📂 Cache directory: ${GAME_PATCH_DIR}"
    echo ""
    
    # Download each patch
    for url in $PATCH_URLS; do
        # Extract filename from URL
        filename=$(basename "$url")
        cache_file="${GAME_PATCH_DIR}/${filename}"
        
        echo "📥 Processing: ${filename}"
        
        # Skip if already cached
        if [ -f "${cache_file}" ]; then
            echo "   ✓ Using cached file"
        else
            echo "   Downloading from ${url}..."
            curl -fL "${url}" -o "${cache_file}.tmp" || {
                echo "   ❌ Failed to download ${url}"
                rm -f "${cache_file}.tmp"
                continue
            }
            mv "${cache_file}.tmp" "${cache_file}"
            echo "   ✓ Downloaded successfully"
        fi
        
        echo "   → ${cache_file}"
        echo ""
    done

    # Copy cached patches into app bundle
    BUNDLE_GAME_DIR="${PATCHES_DEST}/${GAME_SLUG}"
    mkdir -p "${BUNDLE_GAME_DIR}"
    /usr/bin/ditto --rsrc "${GAME_PATCH_DIR}/" "${BUNDLE_GAME_DIR}/"
    echo "   ✓ Copied to bundle: ${BUNDLE_GAME_DIR}"
done

echo "✅ Game patches setup complete"