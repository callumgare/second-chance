#!/bin/bash
# test-games.sh - Build and test Nancy Drew game wrappers
#
# This script:
# 1. Gets all game IDs from lib/game-info.sh
# 2. For each game, calls build-game.sh to build the game wrapper
# 3. Tests the built game with GameTester
# 4. Generates a comprehensive test report with logs

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_RESULTS_BASE_DIR="$SCRIPT_DIR/test-results"
TEST_OUTPUT_DIR=""  # Will be set after parsing arguments
RESULTS_FILE=""  # Will be set after TEST_OUTPUT_DIR is determined
BUILD_GAME_SCRIPT="$SCRIPT_DIR/build-game.sh"
GAME_TESTER_WRAPPER="$SCRIPT_DIR/GameTester/test-game.sh"

# Timeouts
BUILD_TIMEOUT=600  # Seconds to build game wrapper
TEST_TIMEOUT=60    # Seconds to test game

# Options
KEEP_APPS=false
USE_EXISTING=false
DEBUG_MODE=false
SPECIFIC_GAMES=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print usage information
print_usage() {
    cat << EOF
test-games.sh - Build and test Nancy Drew game wrappers

Usage:
  ./test-games.sh [OPTIONS] [GAME_IDS...]

Options:
  --keep-apps        Keep built apps (default: delete after testing)
  --use-existing     Use existing apps from built-apps/ if available
  --debug            Enable debug mode (shows log window in SecondChance)
  --output-dir DIR   Output directory for test results (default: test-results/YYYYMMDD-HHMMSS)
  --help, -h         Show this help message

Arguments:
  GAME_IDS           One or more game IDs to test (omit to test all games)

Examples:
  ./test-games.sh                    # Test all games
  ./test-games.sh --keep-apps        # Test all and keep the apps
  ./test-games.sh --use-existing     # Use existing apps from built-apps/
  ./test-games.sh --output-dir /tmp/test-results  # Custom output directory
  ./test-games.sh old-clock          # Test specific game
  ./test-games.sh old-clock scarlet  # Test multiple specific games

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --keep-apps)
            KEEP_APPS=true
            shift
            ;;
        --use-existing)
            USE_EXISTING=true
            shift
            ;;
        --debug)
            DEBUG_MODE=true
            shift
            ;;
        --output-dir)
            if [[ -n "${2:-}" && ! "$2" =~ ^-- ]]; then
                TEST_RESULTS_BASE_DIR="$2"
                shift 2
            else
                echo "Error: --output-dir requires a directory path"
                echo ""
                print_usage
                exit 1
            fi
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        --*)
            echo "Error: Unknown option: $1"
            echo ""
            print_usage
            exit 1
            ;;
        *)
            SPECIFIC_GAMES+=("$1")
            shift
            ;;
    esac
done

# Set TEST_OUTPUT_DIR and RESULTS_FILE after parsing arguments
TEST_OUTPUT_DIR="$TEST_RESULTS_BASE_DIR/$(date +%Y%m%d-%H%M%S)"
RESULTS_FILE="$TEST_OUTPUT_DIR/test-results.json"

# Initialize results
mkdir -p "$TEST_OUTPUT_DIR"
echo "[]" > "$RESULTS_FILE"

# Track current processes
CURRENT_BUILD_PID=""
CURRENT_TEST_PID=""
INTERRUPTED=false

# Cleanup function
cleanup() {
    # Kill any running SecondChance app instances
    pkill -f "Second Chance.app/Contents/MacOS/Second Chance" 2>/dev/null || true
}

# Handle Ctrl+C
handle_interrupt() {
    INTERRUPTED=true
    echo ""
    log "${YELLOW}⚠️  Interrupted! Cleaning up and generating report...${NC}"
    
    # Kill current build or test process
    if [[ -n "$CURRENT_BUILD_PID" ]]; then
        kill "$CURRENT_BUILD_PID" 2>/dev/null || true
        wait "$CURRENT_BUILD_PID" 2>/dev/null || true
    fi
    if [[ -n "$CURRENT_TEST_PID" ]]; then
        kill "$CURRENT_TEST_PID" 2>/dev/null || true
        wait "$CURRENT_TEST_PID" 2>/dev/null || true
    fi
    
    # Run cleanup
    cleanup
    
    # Generate report and exit
    generate_report
    exit 130
}

trap cleanup EXIT
trap handle_interrupt INT

log() {
    echo -e "$1"
}

# Built-in timeout alternative (timeout command requires installation on macOS)
run_with_timeout() {
    local timeout_duration=$1
    shift
    
    # Run command in background
    "$@" &
    local cmd_pid=$!
    
    # Start timeout monitor in background
    (
        sleep "$timeout_duration"
        echo "Timeout reached after ${timeout_duration}s, terminating process $cmd_pid"
        kill -TERM "$cmd_pid" 2>/dev/null
        sleep 5
        echo "Force killing process $cmd_pid"
        kill -KILL "$cmd_pid" 2>/dev/null
    ) &
    local monitor_pid=$!
    
    # Wait for command to complete
    wait "$cmd_pid"
    local exit_code=$?
    
    # Kill the timeout monitor if command finished early
    kill "$monitor_pid" 2>/dev/null
    wait "$monitor_pid" 2>/dev/null
    
    return $exit_code
}

# Monitor log file and show progress
monitor_log() {
    local log_file="$1"
    local start_time="$2"
    local pid="$3"
    
    # Print log file path
    echo "Log: $log_file"
    
    while kill -0 "$pid" 2>/dev/null; do
        if [[ -f "$log_file" ]]; then
            local lines=$(wc -l < "$log_file" 2>/dev/null || echo 0)
            local elapsed=$(($(date +%s) - start_time))
            printf "\r⏱  Elapsed: %ds | Lines logged: %d" "$elapsed" "$lines"
        fi
        sleep 1
    done
    
    # Final update
    if [[ -f "$log_file" ]]; then
        local lines=$(wc -l < "$log_file" 2>/dev/null || echo 0)
        local elapsed=$(($(date +%s) - start_time))
        printf "\r⏱  Elapsed: %ds | Lines logged: %d\n" "$elapsed" "$lines"
    fi
}

log_result() {
    local game="$1"
    local status="$2"
    local message="$3"
    local build_time="${4:-0}"
    local test_time="${5:-0}"
    
    # Append to JSON results
    local result=$(jq -n \
        --arg game "$game" \
        --arg status "$status" \
        --arg message "$message" \
        --arg build_time "$build_time" \
        --arg test_time "$test_time" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{game: $game, status: $status, message: $message, build_time: $build_time, test_time: $test_time, timestamp: $timestamp}')
    
    jq ". += [$result]" "$RESULTS_FILE" > "$RESULTS_FILE.tmp" && mv "$RESULTS_FILE.tmp" "$RESULTS_FILE"
}

# Generate HTML report
generate_report() {
    log ""
    log "${BLUE}==========================================${NC}"
    log "${BLUE}📊 TEST SUMMARY${NC}"
    log "${BLUE}==========================================${NC}"
    log "${GREEN}✅ Passed:  $PASSED / $TOTAL_GAMES${NC}"
    log "${RED}❌ Failed:  $FAILED / $TOTAL_GAMES${NC}"
    
    # Format total execution time
    local total_minutes=$((TOTAL_EXECUTION_TIME / 60))
    local total_seconds=$((TOTAL_EXECUTION_TIME % 60))
    log "⏱️  Total time: ${total_minutes}m ${total_seconds}s"
    
    log ""
    log "Results saved to: $TEST_OUTPUT_DIR"

    # Generate HTML report
    cat > "$TEST_OUTPUT_DIR/report.html" <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Nancy Drew Games Test Report</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; margin: 20px; }
        h1 { color: #333; }
        .summary { background: #f6f8fa; padding: 20px; border-radius: 6px; margin: 20px 0; }
        .summary h2 { margin-top: 0; }
        .summary-stats { display: flex; flex-wrap: wrap; gap: 20px; align-items: center; }
        .passed { color: #2da44e; font-weight: bold; }
        .failed { color: #cf222e; font-weight: bold; }
        .zero-count { opacity: 0.3; font-weight: normal; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid #d0d7de; }
        th { background: #f6f8fa; font-weight: 600; }
        tr.test-row { cursor: pointer; }
        tr.test-row:hover { background: #f6f8fa; }
        tr.log-row { display: none; }
        tr.log-row.expanded { display: table-row; }
        tr.log-row td { padding: 0; background: #f6f8fa; }
        .log-section { margin: 8px; }
        .log-section h4 { margin: 8px 0; color: #24292e; }
        .log-content { 
            max-height: 300px; 
            overflow-y: auto; 
            padding: 12px; 
            background: #24292e; 
            color: #e1e4e8;
            font-family: 'SF Mono', Monaco, 'Cascadia Code', 'Roboto Mono', Consolas, 'Courier New', monospace;
            font-size: 12px;
            line-height: 1.5;
            white-space: pre-wrap;
            word-wrap: break-word;
            border-radius: 6px;
        }
        .status-badge { padding: 4px 8px; border-radius: 12px; font-size: 12px; font-weight: 600; }
        .status-passed { background: #dafbe1; color: #1a7f37; }
        .status-failed { background: #ffebe9; color: #cf222e; }
        .expand-icon { 
            display: inline-block; 
            width: 0; 
            height: 0; 
            margin-right: 8px;
            border-left: 5px solid #586069;
            border-top: 5px solid transparent;
            border-bottom: 5px solid transparent;
            transition: transform 0.2s;
        }
        .expand-icon.expanded {
            transform: rotate(90deg);
        }
    </style>
</head>
<body>
    <h1>🎮 Nancy Drew Games Test Report</h1>
HTMLEOF

    echo "    <p>Generated: $(date)</p>" >> "$TEST_OUTPUT_DIR/report.html"
    
    # Format total execution time for HTML
    local total_minutes=$((TOTAL_EXECUTION_TIME / 60))
    local total_seconds=$((TOTAL_EXECUTION_TIME % 60))
    
    cat >> "$TEST_OUTPUT_DIR/report.html" <<HTMLEOF
    
    <div class="summary">
        <h2>Summary</h2>
        <div class="summary-stats">
HTMLEOF

    # Only show passed if greater than 0
    if [ $PASSED -gt 0 ]; then
        echo "            <span class=\"passed\">✅ Passed: $PASSED / $TOTAL_GAMES</span>" >> "$TEST_OUTPUT_DIR/report.html"
    fi
    
    # Only show failed if greater than 0
    if [ $FAILED -gt 0 ]; then
        echo "            <span class=\"failed\">❌ Failed: $FAILED / $TOTAL_GAMES</span>" >> "$TEST_OUTPUT_DIR/report.html"
    fi
    
    cat >> "$TEST_OUTPUT_DIR/report.html" <<HTMLEOF
            <span>⏱️ Total execution time: ${total_minutes}m ${total_seconds}s</span>
        </div>
    </div>
    
    <h2>Detailed Results</h2>
    <p style="color: #586069; font-size: 14px;">Click on any row to view logs</p>
    <table>
        <thead>
            <tr>
                <th>Game</th>
                <th>Status</th>
                <th>Message</th>
                <th>Build Time</th>
                <th>Test Time</th>
            </tr>
        </thead>
        <tbody>
HTMLEOF

    # Add results to HTML with expandable logs
    game_index=0
    while IFS= read -r game_result; do
        game_id=$(echo "$game_result" | jq -r '.game')
        status=$(echo "$game_result" | jq -r '.status')
        message=$(echo "$game_result" | jq -r '.message')
        build_time=$(echo "$game_result" | jq -r '.build_time')
        test_time=$(echo "$game_result" | jq -r '.test_time')
        status_upper=$(echo "$status" | tr '[:lower:]' '[:upper:]')
        
        # Write the test row and log row header
        cat >> "$TEST_OUTPUT_DIR/report.html" <<EOF
            <tr class="test-row" onclick="toggleLog($game_index)">
                <td><span class="expand-icon" id="icon-$game_index"></span>$game_id</td>
                <td><span class="status-badge status-$status">$status_upper</span></td>
                <td>$message</td>
                <td>${build_time}s</td>
                <td>${test_time}s</td>
            </tr>
            <tr class="log-row" id="log-$game_index">
                <td colspan="5">
EOF
        
        # Build log
        build_log_path="$TEST_OUTPUT_DIR/$game_id/build-log.txt"
        if [[ -f "$build_log_path" ]]; then
            cat >> "$TEST_OUTPUT_DIR/report.html" <<EOF
                    <div class="log-section">
                        <h4>Build Log</h4>
                        <div class="log-content">
EOF
            sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$build_log_path" >> "$TEST_OUTPUT_DIR/report.html"
            cat >> "$TEST_OUTPUT_DIR/report.html" <<EOF
                        </div>
                    </div>
EOF
        fi
        
        # Test log
        test_log_path="$TEST_OUTPUT_DIR/$game_id/test-log.txt"
        if [[ -f "$test_log_path" ]]; then
            cat >> "$TEST_OUTPUT_DIR/report.html" <<EOF
                    <div class="log-section">
                        <h4>Test Log</h4>
                        <div class="log-content">
EOF
            sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$test_log_path" >> "$TEST_OUTPUT_DIR/report.html"
            cat >> "$TEST_OUTPUT_DIR/report.html" <<EOF
                        </div>
                    </div>
EOF
        fi
        
        # Wrapper log
        wrapper_log_path="$TEST_OUTPUT_DIR/$game_id/wrapper-log.txt"
        if [[ -f "$wrapper_log_path" ]]; then
            cat >> "$TEST_OUTPUT_DIR/report.html" <<EOF
                    <div class="log-section">
                        <h4>Game Wrapper Log</h4>
                        <div class="log-content">
EOF
            sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$wrapper_log_path" >> "$TEST_OUTPUT_DIR/report.html"
            cat >> "$TEST_OUTPUT_DIR/report.html" <<EOF
                        </div>
                    </div>
EOF
        fi
        
        cat >> "$TEST_OUTPUT_DIR/report.html" <<EOF
                </td>
            </tr>
EOF
        
        ((game_index++))
    done < <(jq -c '.[]' "$RESULTS_FILE")

    cat >> "$TEST_OUTPUT_DIR/report.html" <<'HTMLEOF'
        </tbody>
    </table>
    <script>
        function toggleLog(index) {
            const logRow = document.getElementById('log-' + index);
            const icon = document.getElementById('icon-' + index);
            
            if (logRow.classList.contains('expanded')) {
                logRow.classList.remove('expanded');
                icon.classList.remove('expanded');
            } else {
                logRow.classList.add('expanded');
                icon.classList.add('expanded');
            }
        }
    </script>
</body>
</html>
HTMLEOF

    log ""
    log "${GREEN}📄 HTML report: $TEST_OUTPUT_DIR/report.html${NC}"

    # Open the report
    if command -v open &> /dev/null; then
        open "$TEST_OUTPUT_DIR/report.html"
    fi
}

# Get game IDs
if [[ ${#SPECIFIC_GAMES[@]} -gt 0 ]]; then
    GAMES=("${SPECIFIC_GAMES[@]}")
    if [[ ${#SPECIFIC_GAMES[@]} -eq 1 ]]; then
        log "${BLUE}🎮 Testing specific game: ${SPECIFIC_GAMES[0]}${NC}"
    else
        log "${BLUE}🎮 Testing ${#SPECIFIC_GAMES[@]} specific games: ${SPECIFIC_GAMES[*]}${NC}"
    fi
else
    # Source the game info helper
    source "$SCRIPT_DIR/lib/game-info.sh"
    
    # Get all game IDs
    log "${BLUE}🎮 Loading game list...${NC}"
    GAMES=()
    while IFS= read -r game_id; do
        GAMES+=("$game_id")
    done < <(get_all_game_ids)
    
    if [ ${#GAMES[@]} -eq 0 ]; then
        log "${RED}❌ No games found${NC}"
        exit 1
    fi
    
    log "${GREEN}Found ${#GAMES[@]} games${NC}"
fi

# Test statistics
TOTAL_GAMES=${#GAMES[@]}
PASSED=0
FAILED=0
CURRENT_GAME_NUM=0

# Track total execution time
SCRIPT_START_TIME=$(date +%s)

# Test each game
for game_id in "${GAMES[@]}"; do
    ((CURRENT_GAME_NUM++))
    log ""
    log "${BLUE}==========================================${NC}"
    log "${BLUE}🎯 Testing: $game_id (Game $CURRENT_GAME_NUM of $TOTAL_GAMES)${NC}"
    log "${BLUE}==========================================${NC}"
    echo -e "${NC}"  # Ensure color is cleared for remaining text
    
    # Create test output directory for this game
    game_test_dir="$TEST_OUTPUT_DIR/$game_id"
    mkdir -p "$game_test_dir"
    
    build_log="$game_test_dir/build-log.txt"
    test_log="$game_test_dir/test-log.txt"
    wrapper_log="$game_test_dir/wrapper-log.txt"
    
    # Check if we should use existing app
    wrapper_app=""
    using_existing_app=false
    if [[ "$USE_EXISTING" == true ]]; then
        # Get the default app path for this game
        source "$SCRIPT_DIR/lib/game-info.sh"
        expected_app=$(get_default_game_app_path "$game_id")
        
        # Check if the expected app exists
        if [[ -d "$expected_app" ]]; then
            existing_app="$expected_app"
        else
            existing_app=""
        fi
        
        if [[ -n "$existing_app" ]]; then
            echo "♻️ Using existing app from built-apps/"
            echo "Source: $existing_app"
            
            # Use the existing app directly (don't copy it)
            wrapper_app="$existing_app"
            using_existing_app=true
            
            log "${GREEN}✅ Using existing wrapper: $(basename "$wrapper_app")${NC}"
            build_time=0
        else
            echo "ℹ️  No existing app found for $game_id"
            echo "   Looked in: $SCRIPT_DIR/built-apps"
            echo "   Will build from scratch..."
            echo ""
        fi
    fi
    
    # Build the game if we don't have an existing one
    if [[ -z "$wrapper_app" ]]; then
        # Build the game
        echo "📦 Building game wrapper..."
        
        # Build command with optional debug flag
        build_cmd=("$BUILD_GAME_SCRIPT" "$game_id" --output-dir "$game_test_dir")
        if [[ "$DEBUG_MODE" == true ]]; then
            build_cmd+=(--debug)
        fi
        
        echo "Command: ${build_cmd[*]}"
        echo ""
    
        build_start=$(date +%s)
        
        set +e
        # Use script to disable buffering for real-time log output (macOS built-in)
        run_with_timeout "$BUILD_TIMEOUT" script -q /dev/null "${build_cmd[@]}" > "$build_log" 2>&1 &
        build_pid=$!
        CURRENT_BUILD_PID=$build_pid
        
        # Monitor the build log
        monitor_log "$build_log" "$build_start" "$build_pid"
        
        # Wait for build to complete and get exit code
        wait "$build_pid"
        build_exit_code=$?
        CURRENT_BUILD_PID=""
        set -e
        
        # Check if interrupted
        if [[ "$INTERRUPTED" == true ]]; then
            break
        fi
        
        build_end=$(date +%s)
        build_time=$((build_end - build_start))
        
        if [[ $build_exit_code -ne 0 ]]; then
            log "${RED}❌ Build failed or timed out (${build_time}s)${NC}"
            log_result "$game_id" "failed" "Build failed or timed out" "$build_time" "0"
            ((FAILED++))
            continue
        fi
        
        log "${GREEN}✅ Build succeeded (${build_time}s)${NC}"
        
        # Find the built app
        wrapper_app=$(find "$game_test_dir" -name "Nancy Drew - *.app" -type d -maxdepth 1 | head -1)
        
        if [[ -z "$wrapper_app" ]]; then
            log "${RED}❌ Wrapper app not created${NC}"
            log_result "$game_id" "failed" "Wrapper not created" "$build_time" "0"
            ((FAILED++))
            continue
        fi
        
        log "${GREEN}✅ Wrapper created: $(basename "$wrapper_app")${NC}"
    fi
    
    # Test the game
    echo ""
    echo "🚀 Testing game with GameTester..."
    echo "Command: $GAME_TESTER_WRAPPER \"$wrapper_app\" --timeout $TEST_TIMEOUT --log \"$wrapper_log\""
    echo ""
    
    test_start=$(date +%s)
    
    set +e
    # Run GameTester wrapper and capture output to log file
    run_with_timeout $((TEST_TIMEOUT + 60)) "$GAME_TESTER_WRAPPER" "$wrapper_app" --log "$wrapper_log" --timeout "$TEST_TIMEOUT" > "$test_log" 2>&1 &
    test_pid=$!
    CURRENT_TEST_PID=$test_pid
    
    # Monitor the test log
    monitor_log "$test_log" "$test_start" "$test_pid"
    
    # Wait for test to complete and get exit code
    wait "$test_pid"
    test_exit_code=$?
    CURRENT_TEST_PID=""
    set -e
    
    # Check if interrupted
    if [[ "$INTERRUPTED" == true ]]; then
        break
    fi
    
    test_end=$(date +%s)
    test_time=$((test_end - test_start))
    
    if [[ $test_exit_code -eq 0 ]]; then
        log "${GREEN}✅ Test passed (${test_time}s)${NC}"
        log_result "$game_id" "passed" "Build and test successful" "$build_time" "$test_time"
        ((PASSED++))
    else
        log "${RED}❌ Test failed (${test_time}s)${NC}"
        log_result "$game_id" "failed" "Test failed (exit code: $test_exit_code)" "$build_time" "$test_time"
        ((FAILED++))
    fi
    
    # Delete app unless --keep-apps or using existing app from built-apps
    if [[ "$KEEP_APPS" == false && "$using_existing_app" == false ]]; then
        log "${YELLOW}🧹 Cleaning up wrapper${NC}"
        rm -rf "$wrapper_app" 2>/dev/null || true
    fi
done

# Calculate total execution time
SCRIPT_END_TIME=$(date +%s)
TOTAL_EXECUTION_TIME=$((SCRIPT_END_TIME - SCRIPT_START_TIME))

# Generate final report
generate_report

# Exit with appropriate code
if [[ $FAILED -gt 0 ]]; then
    exit 1
else
    exit 0
fi
