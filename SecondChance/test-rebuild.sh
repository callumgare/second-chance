#!/bin/bash
# Quick rebuild and test script for SecondChance app

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
SKIP_BUILD=false
STRICT_INSTALL=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --strict-install)
            STRICT_INSTALL=true
            shift
            ;;
        *)
            break
            ;;
    esac
done

cd "$(dirname "$0")"

# Build the app (unless skipped)
if [[ "$SKIP_BUILD" == false ]]; then
    echo -e "${BLUE}🔨 Building SecondChance...${NC}"
    
    xcodebuild -project SecondChance.xcodeproj \
        -scheme SecondChance \
        -configuration Debug \
        -derivedDataPath ./DerivedData \
        build #| grep -E '(Build succeeded|error|warning)' || true
    
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo -e "${RED}❌ Build failed${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✅ Build succeeded${NC}"
else
    echo -e "${BLUE}⚡ Skipping build (using existing app)${NC}"
fi

# Get the built app path
APP_PATH="./DerivedData/Build/Products/Debug/SecondChance.app"

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}❌ App not found at $APP_PATH${NC}"
    exit 1
fi

echo -e "${BLUE}📦 App built at: $APP_PATH${NC}"

# Optionally launch the app
if [ "${1}" == "--launch" ] || [ "${1}" == "-l" ]; then
    echo -e "${BLUE}🚀 Launching app...${NC}"
    open "$APP_PATH"
fi

# Optionally run with test configuration
if [ "${1}" == "--test" ] || [ "${1}" == "-t" ]; then
    TEST_DISK="${2:-/Users/callumgare/repos/second-chance/installers/blackmoor-manor}"
    TEST_OUTPUT_DIR="/Users/callumgare/repos/second-chance/test-output"
    
    echo -e "${BLUE}🧪 Running test installation...${NC}"
    echo -e "   Test disk: $TEST_DISK"
    echo -e "   Output: $TEST_OUTPUT_DIR${NC}"
    echo ""
    
    # Kill any existing SecondChance test instances
    if pgrep -f "SecondChance.app" > /dev/null; then
        echo -e "${BLUE}🔄 Closing previous test instances...${NC}"
        pkill -f "SecondChance.app" || true
        sleep 1
    fi
    
    # Remove existing test output to ensure clean state
    if [ -d "$TEST_OUTPUT_DIR" ]; then
        echo -e "${BLUE}🗑️  Removing previous test output...${NC}"
        rm -rf "$TEST_OUTPUT_DIR"
    fi
    
    # Launch with environment variables for test mode
    echo -e "${BLUE}🚀 Launching app and capturing output...${NC}"
    echo ""
    
    # Run the executable directly to capture stdout/stderr
    # Set STRICT_INSTALL=true to prevent fallback to interactive mode if --strict-install flag was passed
    if [[ "$STRICT_INSTALL" == true ]]; then
        TEST_MODE=true TEST_DISK_PATH="$TEST_DISK" STRICT_INSTALL=true "$APP_PATH/Contents/MacOS/SecondChance" 2>&1
    else
        TEST_MODE=true TEST_DISK_PATH="$TEST_DISK" "$APP_PATH/Contents/MacOS/SecondChance" 2>&1
    fi
    
    echo ""
    echo -e "${BLUE}💡 Tip: Check output in: test-output/Nancy Drew - [Game Title].app${NC}"
fi

echo -e "${GREEN}✨ Done!${NC}"
