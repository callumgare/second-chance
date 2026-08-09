#!/bin/bash
# build.sh - Build GameTester executable
#
# This script compiles all GameTester Swift modules into a single executable.
# It uses a hash-based cache to skip rebuilding when sources haven't changed.
#
# Usage:
#   ./build.sh [--force]
#
# Options:
#   --force    Force rebuild even if cache is valid

# aaaaa-b

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME_TESTER_EXECUTABLE="$SCRIPT_DIR/GameTester"
BUILD_CACHE_FILE="$GAME_TESTER_EXECUTABLE.build-cache"

# Parse arguments
FORCE_BUILD=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE_BUILD=true
fi

# Calculate hash of all source files
calculate_source_hash() {
    local hash_input=""
    local parent_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
    
    # Find all Swift files in GameTester directory
    while IFS= read -r -d '' file; do
        # Get modification time and filename
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS stat format
            local mtime=$(stat -f "%m" "$file" 2>/dev/null || echo "0")
        else
            # Linux stat format
            local mtime=$(stat -c "%Y" "$file" 2>/dev/null || echo "0")
        fi
        # Use relative path from parent directory
        local relative_path="${file#$parent_dir/}"
        hash_input+="$relative_path:$mtime"$'\n'
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -name "*.swift" -type f -print0 2>/dev/null)
    
    # Find all files in assets directory if it exists
    if [[ -d "$SCRIPT_DIR/assets" ]]; then
        while IFS= read -r -d '' file; do
            if [[ "$OSTYPE" == "darwin"* ]]; then
                local mtime=$(stat -f "%m" "$file" 2>/dev/null || echo "0")
            else
                local mtime=$(stat -c "%Y" "$file" 2>/dev/null || echo "0")
            fi
            # Use relative path from parent directory
            local relative_path="${file#$parent_dir/}"
            hash_input+="$relative_path:$mtime"$'\n'
        done < <(find "$SCRIPT_DIR/assets" -type f -print0 2>/dev/null)
    fi
    
    # Generate hash from the input
    echo -n "$hash_input" | shasum -a 256 | awk '{print $1}'
}

# Check if rebuild is needed
needs_rebuild() {
    # If force build requested, always rebuild
    if [[ "$FORCE_BUILD" == "true" ]]; then
        [[ "${DEBUG:-}" == "true" ]] && echo -e "${BLUE}[DEBUG] Force build requested${NC}" >&2
        return 0  # true - needs rebuild
    fi
    
    # If executable doesn't exist, need to build
    if [[ ! -f "$GAME_TESTER_EXECUTABLE" ]]; then
        [[ "${DEBUG:-}" == "true" ]] && echo -e "${BLUE}[DEBUG] Executable not found: $GAME_TESTER_EXECUTABLE${NC}" >&2
        return 0  # true - needs rebuild
    fi
    
    # If cache file doesn't exist, need to rebuild
    if [[ ! -f "$BUILD_CACHE_FILE" ]]; then
        [[ "${DEBUG:-}" == "true" ]] && echo -e "${BLUE}[DEBUG] Cache file not found: $BUILD_CACHE_FILE${NC}" >&2
        return 0  # true - needs rebuild
    fi
    
    # Calculate current hash
    local current_hash=$(calculate_source_hash)
    local cached_hash=$(cat "$BUILD_CACHE_FILE" 2>/dev/null || echo "")
    
    if [[ "${DEBUG:-}" == "true" ]]; then
        echo -e "${BLUE}[DEBUG] Current hash: $current_hash${NC}" >&2
        echo -e "${BLUE}[DEBUG] Cached hash:  $cached_hash${NC}" >&2
    fi
    
    # Compare hashes
    if [[ "$current_hash" != "$cached_hash" ]]; then
        [[ "${DEBUG:-}" == "true" ]] && echo -e "${BLUE}[DEBUG] Hash mismatch - rebuild needed${NC}" >&2
        return 0  # true - needs rebuild
    fi
    
    [[ "${DEBUG:-}" == "true" ]] && echo -e "${BLUE}[DEBUG] Hashes match - no rebuild needed${NC}" >&2
    return 1  # false - no rebuild needed
}

# Build GameTester
build_game_tester() {
    echo -e "${BLUE}🔨 Building GameTester...${NC}"
    
    local swift_files=(
        "$SCRIPT_DIR/Configuration.swift"
        "$SCRIPT_DIR/InputAutomation.swift"
        "$SCRIPT_DIR/WindowManagement.swift"
        "$SCRIPT_DIR/ProcessManagement.swift"
        "$SCRIPT_DIR/ComputerVision.swift"
        "$SCRIPT_DIR/TestOrchestration.swift"
        "$SCRIPT_DIR/main.swift"
    )
    
    # Verify all source files exist
    for file in "${swift_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            echo -e "${RED}Error: Source file not found: $file${NC}"
            exit 1
        fi
    done
    
    # Compile
    if swiftc -o "$GAME_TESTER_EXECUTABLE" "${swift_files[@]}" 2>&1; then
        echo -e "${GREEN}✅ GameTester compiled successfully${NC}"
        
        # Save the current hash to cache
        calculate_source_hash > "$BUILD_CACHE_FILE"
        
        # Make executable
        chmod +x "$GAME_TESTER_EXECUTABLE" 2>/dev/null || true
        
        return 0
    else
        echo -e "${RED}❌ GameTester compilation failed${NC}"
        return 1
    fi
}

# Main logic
if needs_rebuild; then
    if [[ "$FORCE_BUILD" == "true" ]]; then
        echo -e "${YELLOW}⚠️  Force rebuild requested${NC}"
    else
        echo -e "${YELLOW}⚠️  GameTester source files have changed or executable missing${NC}"
    fi
    
    if ! build_game_tester; then
        exit 1
    fi
else
    echo -e "${GREEN}✓ GameTester is up to date${NC}"
fi
