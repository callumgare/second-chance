#!/usr/bin/env bash

# build.sh - Build the SecondChance app
#
# Usage:
#   ./build.sh              # Build with xcbeautify output (default)
#   ./build.sh --quiet      # Suppress all output
#   ./build.sh --raw-logs   # Raw xcodebuild output (no xcbeautify)
#

# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
QUIET=false
RAW_LOGS=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --quiet|-q)
            QUIET=true
            shift
            ;;
        --raw-logs)
            RAW_LOGS=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--quiet|-q] [--raw-logs]"
            exit 1
            ;;
    esac
done

if [[ "$QUIET" == true && "$RAW_LOGS" == true ]]; then
    echo -e "${RED}❌ --quiet and --raw-logs are mutually exclusive${NC}" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIVED_DATA_PATH="$SCRIPT_DIR/DerivedData"

echo -e "${BLUE}🔨 Building SecondChance...${NC}"

if [[ "$QUIET" == true ]]; then
    XCBEAUTIFY_OPTIONS="--quiet --disable-logging"
elif [[ "$RAW_LOGS" == true ]]; then
    XCBEAUTIFY_OPTIONS="--preserve-unbeautified"
else
    XCBEAUTIFY_OPTIONS=""
fi

NSUnbufferedIO=YES xcodebuild -project "$SCRIPT_DIR/SecondChance.xcodeproj" \
    -scheme SecondChance \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build 2>&1 | xcbeautify $XCBEAUTIFY_OPTIONS

echo -e "${BLUE}📦 App built at: $DERIVED_DATA_PATH/Build/Products/Debug/Second Chance.app${NC}"
