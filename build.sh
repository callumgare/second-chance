#!/bin/bash
# build.sh - Build the SecondChance app
#
# Usage:
#   ./build.sh              # Build with full output
#   ./build.sh --quiet      # Build with minimal output
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
QUIET=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --quiet|-q)
            QUIET=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--quiet|-q]"
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIVED_DATA_PATH="$SCRIPT_DIR/DerivedData"

echo -e "${BLUE}🔨 Building SecondChance...${NC}"

# Redirect output if quiet mode is enabled
if [[ "$QUIET" == true ]]; then
    BUILD_OUTPUT=">/dev/null 2>&1"
else
    BUILD_OUTPUT=""
fi

if eval "xcodebuild -project '$SCRIPT_DIR/SecondChance.xcodeproj' \
    -scheme SecondChance \
    -configuration Debug \
    -derivedDataPath '$DERIVED_DATA_PATH' \
    build $BUILD_OUTPUT"; then
    echo -e "${GREEN}✅ Build succeeded${NC}"
else
    echo -e "${RED}❌ Build failed${NC}"
    exit 1
fi

echo -e "${BLUE}📦 App built at: $DERIVED_DATA_PATH/Build/Products/Debug/SecondChance.app${NC}"
