#!/bin/bash
# run-tests.sh - Unified test runner for Second Chance
#
# This script provides a simple interface to run different types of tests:
# - Unit tests (Swift Testing)
# - Integration tests (bash script with real installers)
# - Quick smoke tests
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

show_help() {
    cat << EOF
🧪 Second Chance Test Runner

Usage:
  ./run-tests.sh [command] [options]

Commands:
  unit              Run Swift unit tests (fast, ~5 seconds)
  integration       Run full integration tests (slow, ~2-3 hours)
  quick [game]      Run quick integration test on one game
  all               Run both unit and integration tests

Examples:
  ./run-tests.sh unit                    # Run Swift unit tests
  ./run-tests.sh quick scarlet-hand      # Test one specific game
  ./run-tests.sh integration             # Test all games
  ./run-tests.sh all                     # Everything

Options:
  -h, --help        Show this help message

EOF
}

run_unit_tests() {
    echo -e "${BLUE}🧪 Running Swift unit tests...${NC}"
    cd "$SCRIPT_DIR/SecondChance"
    
    # Run tests in Xcode
    if command -v xcodebuild &> /dev/null; then
        xcodebuild test -scheme SecondChance -destination 'platform=macOS' 2>&1 | \
            grep -E "Test Suite|Test Case|Executed|passed|failed" || true
    else
        echo -e "${YELLOW}⚠️  xcodebuild not found, using swift test${NC}"
        swift test
    fi
    
    echo -e "${GREEN}✅ Unit tests complete${NC}"
}

run_integration_tests() {
    echo -e "${BLUE}🎮 Running integration tests (this will take a while)...${NC}"
    "$SCRIPT_DIR/test-all-games.sh" "$@"
}

run_quick_test() {
    local game="$1"
    echo -e "${BLUE}⚡ Running quick test for $game...${NC}"
    "$SCRIPT_DIR/test-all-games.sh" "$game"
}

# Parse command
case "${1:-unit}" in
    unit)
        run_unit_tests
        ;;
    integration)
        shift
        run_integration_tests "$@"
        ;;
    quick)
        if [[ -z "${2:-}" ]]; then
            echo "Error: Please specify a game slug"
            echo "Example: ./run-tests.sh quick scarlet-hand"
            exit 1
        fi
        run_quick_test "$2"
        ;;
    all)
        run_unit_tests
        echo ""
        read -p "Unit tests complete. Run integration tests? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            run_integration_tests
        fi
        ;;
    -h|--help|help)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
