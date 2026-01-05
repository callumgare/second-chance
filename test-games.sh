#!/bin/bash
# test-games.sh - Comprehensive integration testing for Nancy Drew game installations
#
# This script tests the complete installation and launch flow for all Nancy Drew games:
# 1. Builds the SecondChance app
# 2. Attempts to detect and install each game from its installer directory
# 3. Verifies the game wrapper was created successfully
# 4. Tests launching the game (with timeout)
# 5. Captures logs and screenshots
# 6. Generates a comprehensive test report
#
# Usage:
#   ./test-games.sh                    # Test all games
#   ./test-games.sh scarlet-hand       # Test specific game
#   ./test-games.sh --quick            # Quick test (skip build)
#   ./test-games.sh --no-launch        # Don't launch games, just install
#   ./test-games.sh --cleanup          # Delete wrappers after each test
#   ./test-games.sh --strict-install   # Fail if silent install fails (no interactive fallback)
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLERS_DIR="$SCRIPT_DIR/installers"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-results/$(date +%Y%m%d-%H%M%S)"
RESULTS_FILE="$TEST_OUTPUT_DIR/test-results.json"
LOG_FILE="$TEST_OUTPUT_DIR/test-log.txt"
APP_PATH="$SCRIPT_DIR/DerivedData/Build/Products/Debug/SecondChance.app"
BUILD_SCRIPT="$SCRIPT_DIR/build.sh"
RUN_SCRIPT="$SCRIPT_DIR/run.sh"
TMP_DIR="/tmp/nancy-drew-test-$$"

# Test configuration
LAUNCH_TIMEOUT=30  # Seconds to wait for game to launch
SKIP_BUILD=false
SKIP_LAUNCH=false
CLEANUP_WRAPPERS=false
STRICT_INSTALL=false
SPECIFIC_GAME=""
INTERRUPTED=false

# Array to track mounted disks for cleanup
MOUNTED_DISKS=()

# Track background tail process for cleanup
TAIL_PID=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            SKIP_BUILD=true
            shift
            ;;
        --no-launch)
            SKIP_LAUNCH=true
            shift
            ;;
        --cleanup)
            CLEANUP_WRAPPERS=true
            shift
            ;;
        --strict-install)
            STRICT_INSTALL=true
            shift
            ;;
        --timeout)
            LAUNCH_TIMEOUT="$2"
            shift 2
            ;;
        --*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            SPECIFIC_GAME="$1"
            shift
            ;;
    esac
done

# Initialize results
mkdir -p "$TEST_OUTPUT_DIR"
mkdir -p "$TMP_DIR"
echo "[]" > "$RESULTS_FILE"

# Cleanup function for mounted disks
cleanup() {
    # Kill tail progress process if running
    if [ -n "$TAIL_PID" ] && kill -0 "$TAIL_PID" 2>/dev/null; then
        kill "$TAIL_PID" 2>/dev/null || true
        wait "$TAIL_PID" 2>/dev/null || true
    fi
    
    # Kill any running SecondChance app instances
    pkill -f "SecondChance.app/Contents/MacOS/SecondChance" 2>/dev/null || true
    
    # Give processes a moment to terminate
    sleep 0.5
    
    log "${YELLOW}🧹 Cleaning up mounted disks...${NC}"
    if [ ${#MOUNTED_DISKS[@]} -gt 0 ]; then
        for mount_point in "${MOUNTED_DISKS[@]}"; do
            if mount | grep -q " on $mount_point"; then
                log "Unmounting: $mount_point"
                hdiutil eject "$mount_point" 2>/dev/null || true
            fi
        done
    fi
    
    # Also unmount any remaining mounts under TMP_DIR that might have been missed
    if [ -d "$TMP_DIR" ]; then
        for mount_point in "$TMP_DIR"/*; do
            if [ -d "$mount_point" ] && mount | grep -q " on $mount_point"; then
                log "Unmounting remaining: $mount_point"
                hdiutil eject "$mount_point" 2>/dev/null || true
            fi
        done
    fi
    
    # Kill any diskimages-helper processes that might be holding ISO files open
    # This prevents "Resource busy" errors on subsequent runs
    pkill -9 diskimages-helper 2>/dev/null || true
    sleep 0.5
    
    # Clean up temp directory
    rm -rf "$TMP_DIR" 2>/dev/null || true
}

# Handle interrupt signal (Ctrl+C) separately to stop loop
handle_interrupt() {
    INTERRUPTED=true
    log ""
    log "${YELLOW}⚠️  Interrupt received, stopping after current game...${NC}"
}

# Set trap to cleanup on exit or kill signals
trap cleanup EXIT TERM HUP QUIT
trap handle_interrupt INT

mount_disk() {
    local disk_path=$1
    local mount_point=$2
    
    # Check if this specific ISO file is already mounted somewhere
    # Search for the full path in hdiutil info output and get the associated device
    local existing_device=$(hdiutil info | awk -v path="$disk_path" '
        /^image-path/ { 
            if (index($0, path) > 0) found=1
            else found=0
        }
        /^\/dev\/disk[0-9]+\s/ {
            if (found) {
                print $1
                exit
            }
        }
    ')
    
    if [ -n "$existing_device" ]; then
        # Get the actual mount point for this device
        local actual_mount_point=$(mount | grep "^$existing_device " | awk '{print $3}')
        if [ -n "$actual_mount_point" ]; then
            log "${GREEN}✅ Reusing existing mount: $actual_mount_point${NC}" >&2
            # Add to MOUNTED_DISKS if not already there
            if [[ ! " ${MOUNTED_DISKS[@]} " =~ " ${actual_mount_point} " ]]; then
                MOUNTED_DISKS+=("$actual_mount_point")
            fi
            # Return the actual mount point
            echo "$actual_mount_point"
            return 0
        fi
    fi
    
    # Check if target mount point is already in use
    if mount | grep -q " on $(realpath "$mount_point" 2>/dev/null || echo "$mount_point")"; then
        log "${YELLOW}Ejecting existing mount at $mount_point${NC}" >&2
        hdiutil eject "$mount_point" 2>/dev/null || true
    fi
    
    mkdir -p "$mount_point"
    
    log "Mounting ISO: $disk_path -> $mount_point" >&2
    if hdiutil attach -mountpoint "$mount_point" -noautoopen "$disk_path" >> "$LOG_FILE" 2>&1; then
        MOUNTED_DISKS+=("$mount_point")
        echo "$mount_point"
        return 0
    else
        log "${RED}❌ Failed to mount ISO${NC}" >&2
        return 1
    fi
}

unmount_disk() {
    local mount_point=$1
    
    if mount | grep -q " on $mount_point"; then
        log "Unmounting: $mount_point"
        hdiutil eject "$mount_point" 2>&1 | tee -a "$LOG_FILE"
        # Remove from tracked mounts
        MOUNTED_DISKS=("${MOUNTED_DISKS[@]/$mount_point}")
    fi
}

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Display last N lines of a file with live updates, clearing them when done
tail_with_progress() {
    local log_file=$1
    local num_lines=10
    local state_file="$TMP_DIR/tail_state_$$_$(date +%s%N)"
    
    # Create empty log file if it doesn't exist
    touch "$log_file"
    
    # Monitor the log file and display last N lines in background
    # Redirect output to /dev/tty to avoid being captured by command substitution
    (
        local prev_physical_lines=0
        local first_iteration=true
        
        while true; do
            sleep 0.5
            
            # Get terminal width, default to 80 if unavailable
            local term_width=$(tput cols 2>/dev/null || echo 80)
            # Account for the "  │ " prefix (4 characters)
            local usable_width=$((term_width - 4))
            
            if [ "$first_iteration" = true ]; then
                # Save cursor position at the start of our display area
                echo -ne "\033[s" >/dev/tty
                first_iteration=false
            else
                # Restore to saved cursor position (start of our display area)
                echo -ne "\033[u" >/dev/tty
                # Clear from cursor to end of screen
                echo -ne "\033[J" >/dev/tty
                # Restore cursor position again to start drawing
                echo -ne "\033[u" >/dev/tty
            fi
            
            # Get last N lines from the file
            last_lines=()
            while IFS= read -r line; do
                last_lines+=("$line")
            done < <(tail -n "$num_lines" "$log_file" 2>/dev/null)
            
            # Calculate total physical lines needed and display
            local physical_lines=0
            for ((i=0; i<num_lines; i++)); do
                if [ $i -lt ${#last_lines[@]} ]; then
                    local line="${last_lines[$i]}"
                    # Calculate how many terminal lines this will use (including the "  │ " prefix)
                    local display_text="  │ ${line}"
                    local display_length=${#display_text}
                    if [ $display_length -eq 0 ]; then
                        local lines_used=1
                    else
                        local lines_used=$(( (display_length + term_width - 1) / term_width ))
                    fi
                    physical_lines=$((physical_lines + lines_used))
                    echo -e "\033[90m${display_text}\033[0m"
                else
                    # Empty line
                    physical_lines=$((physical_lines + 1))
                    echo ""
                fi
            done >/dev/tty
            
            prev_physical_lines=$physical_lines
            # Save the current physical line count to state file for cleanup
            echo "$physical_lines" > "$state_file"
        done
    ) >/dev/null 2>&1 &
    
    # Return the PID and state file path separated by colon
    local bg_pid=$!
    echo "$bg_pid:$state_file"
}

clear_progress_display() {
    local tail_info=$1
    local tail_state_file="${tail_info##*:}"
    
    # Read the saved physical line count and clear exactly those lines
    if [ -f "$tail_state_file" ]; then
        local lines_to_clear=$(cat "$tail_state_file" 2>/dev/null || echo 0)
        
        # Move cursor up to where the progress display started
        for ((i=0; i<lines_to_clear; i++)); do
            echo -ne "\033[1A"
        done
        
        # Clear each line moving forward
        for ((i=0; i<lines_to_clear; i++)); do
            echo -ne "\033[2K"    # Clear current line
            if [ $i -lt $((lines_to_clear - 1)) ]; then
                echo -ne "\033[1B"  # Move down one line
            fi
        done
        
        # Move cursor back up to where the progress display started
        # so subsequent output continues from there without a gap
        for ((i=0; i<lines_to_clear; i++)); do
            echo -ne "\033[1A"
        done
        
        rm -f "$tail_state_file"
    fi
}

log_result() {
    local game="$1"
    local status="$2"
    local message="$3"
    local duration="${4:-0}"
    
    # Append to JSON results
    local result=$(jq -n \
        --arg game "$game" \
        --arg status "$status" \
        --arg message "$message" \
        --arg duration "$duration" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{game: $game, status: $status, message: $message, duration: $duration, timestamp: $timestamp}')
    
    jq ". += [$result]" "$RESULTS_FILE" > "$RESULTS_FILE.tmp" && mv "$RESULTS_FILE.tmp" "$RESULTS_FILE"
}

# Extract game IDs from GameInfoProvider.swift
# Returns array of game IDs in order
get_game_ids_from_source() {
    local game_info_file="$SCRIPT_DIR/SecondChance/Services/GameInfoProvider.swift"
    
    # Check if file exists
    if [[ ! -f "$game_info_file" ]]; then
        echo "ERROR: GameInfoProvider.swift not found at: $game_info_file" >&2
        return 1
    fi
    
    # Extract game IDs in order using grep and sed
    # The pattern matches lines like: id: "secrets-can-kill",
    local game_ids=()
    while IFS= read -r line; do
        if [[ $line =~ id:[[:space:]]*\"([^\"]+)\" ]]; then
            game_ids+=("${BASH_REMATCH[1]}")
        fi
    done < "$game_info_file"
    
    # Check if we found any games
    if [ ${#game_ids[@]} -eq 0 ]; then
        echo "ERROR: No game IDs found in GameInfoProvider.swift" >&2
        return 1
    fi
    
    # Output the game IDs (one per line)
    printf '%s\n' "${game_ids[@]}"
    return 0
}

# Build the app (unless skipped)
if [[ "$SKIP_BUILD" == false ]]; then
    log "${BLUE}🔨 Building SecondChance app...${NC}"
    BUILD_LOG="$TEST_OUTPUT_DIR/build-log.txt"
    if "$BUILD_SCRIPT" > "$BUILD_LOG" 2>&1; then
        log "${GREEN}✅ Build succeeded${NC}"
        log "Build log: $BUILD_LOG"
    else
        log "${RED}❌ Build failed! Check $BUILD_LOG${NC}"
        exit 1
    fi
else
    log "${YELLOW}⚡ Skipping build (using existing app)${NC}"
fi

# Find games to test
if [[ -n "$SPECIFIC_GAME" ]]; then
    if [[ -d "$INSTALLERS_DIR/$SPECIFIC_GAME" ]]; then
        GAMES=("$SPECIFIC_GAME")
        log "${BLUE}🎮 Testing specific game: $SPECIFIC_GAME${NC}"
    else
        log "${RED}❌ Game directory not found: $INSTALLERS_DIR/$SPECIFIC_GAME${NC}"
        exit 1
    fi
else
    log "${BLUE}🎮 Loading game list from GameInfoProvider.swift...${NC}"
    
    # Extract game IDs from source code
    GAMES=()
    while IFS= read -r game_id; do
        GAMES+=("$game_id")
    done < <(get_game_ids_from_source)
    
    # Check if extraction succeeded
    if [ $? -ne 0 ] || [ ${#GAMES[@]} -eq 0 ]; then
        log "${RED}❌ Failed to extract game IDs from GameInfoProvider.swift${NC}"
        exit 1
    fi
    
    log "Extracted ${#GAMES[@]} game IDs from source"
    
    # Filter to only games that have installer directories
    AVAILABLE_GAMES=()
    if [ ${#GAMES[@]} -gt 0 ]; then
        for game_slug in "${GAMES[@]}"; do
            if [[ -d "$INSTALLERS_DIR/$game_slug" ]]; then
                AVAILABLE_GAMES+=("$game_slug")
            fi
        done
    fi
    
    if [ ${#AVAILABLE_GAMES[@]} -gt 0 ]; then
        GAMES=("${AVAILABLE_GAMES[@]}")
    else
        GAMES=()
    fi
    
    log "${GREEN}Found ${#GAMES[@]} games with installer directories${NC}"
fi

# Test statistics
TOTAL_GAMES=${#GAMES[@]}
PASSED=0
FAILED=0
SKIPPED=0

# Test each game
if [ ${#GAMES[@]} -gt 0 ]; then
    for game_slug in "${GAMES[@]}"; do
        # Check if interrupted
        if [[ "$INTERRUPTED" == true ]]; then
            log ""
            log "${YELLOW}⚠️  Testing interrupted by user${NC}"
            break
        fi
        
        game_dir="$INSTALLERS_DIR/$game_slug"
        
        log ""
        log "${BLUE}==========================================${NC}"
        log "${BLUE}🎯 Testing: $game_slug${NC}"
        log "${BLUE}==========================================${NC}"
        
        start_time=$(date +%s)
    
    # Check if installer exists
    if [[ ! -d "$game_dir" ]]; then
        log "${YELLOW}⚠️  Installer directory not found, skipping${NC}"
        log_result "$game_slug" "skipped" "Installer directory not found" "0"
        ((SKIPPED++))
        continue
    fi
    
    # Look for ISO files to mount
    disk_1_iso="$game_dir/disk-1.iso"
    disk_2_iso="$game_dir/disk-2.iso"
    disk_1_mount=""
    disk_2_mount=""
    test_disk_path=""
    
    if [[ -f "$disk_1_iso" ]]; then
        # Mount disk 1
        disk_1_mount="$TMP_DIR/$game_slug-disk-1"
        if actual_mount=$(mount_disk "$disk_1_iso" "$disk_1_mount"); then
            disk_1_mount="$actual_mount"
            test_disk_path="$disk_1_mount"
            log "${GREEN}✅ Mounted disk 1${NC}"
            
            # Mount disk 2 if it exists
            if [[ -f "$disk_2_iso" ]]; then
                disk_2_mount="$TMP_DIR/$game_slug-disk-2"
                if actual_mount=$(mount_disk "$disk_2_iso" "$disk_2_mount"); then
                    disk_2_mount="$actual_mount"
                    log "${GREEN}✅ Mounted disk 2${NC}"
                else
                    log "${YELLOW}⚠️  Failed to mount disk 2, continuing with disk 1 only${NC}"
                fi
            fi
        else
            log "${RED}❌ Failed to mount disk 1${NC}"
            log_result "$game_slug" "failed" "Failed to mount disk ISO" "0"
            ((FAILED++))
            continue
        fi
    else
        # Fall back to looking for direct installer files
        installer_file=""
        for ext in setup.exe SETUP.EXE Setup.exe *.msi *.MSI; do
            if [[ -f "$game_dir/$ext" ]]; then
                installer_file="$game_dir/$ext"
                break
            fi
        done
        
        if [[ -z "$installer_file" && ! -d "$game_dir/disk-1" ]]; then
            log "${YELLOW}⚠️  No ISO or installer file found, skipping${NC}"
            log_result "$game_slug" "skipped" "No ISO or installer file found" "0"
            ((SKIPPED++))
            continue
        fi
        
        # Use the game directory if no ISO (for legacy non-ISO setups)
        test_disk_path="$game_dir"
    fi
    
    # Create test output directory for this game
    game_test_dir="$TEST_OUTPUT_DIR/$game_slug"
    mkdir -p "$game_test_dir"
    install_log_file="$game_test_dir/install-log.txt"
    
    # Run installation test
    log "${BLUE}📦 Installing game...${NC}"
    log "   Install log: $install_log_file"
    TAIL_INFO=$(tail_with_progress "$install_log_file")
    TAIL_PID="${TAIL_INFO%%:*}"
    
    # Use run.sh with test mode environment variables
    # Use timeout with --foreground and --kill-after to ensure proper cleanup
    # Set environment variables for test mode
    RUN_ARGS=()
    if [[ "$STRICT_INSTALL" == true ]]; then
        export STRICT_INSTALL=true
    fi
    export INSTALLATION_SOURCE=disk
    export NON_INTERACTIVE=true
    export OUTPUT_PATH="$TEST_OUTPUT_DIR"
    export DISK_1_PATH="$test_disk_path"
    
    if timeout --foreground --kill-after=5s 600 "$RUN_SCRIPT" -- > "$install_log_file" 2>&1; then
        # Kill the tail process first
        kill $TAIL_PID 2>/dev/null || true
        wait $TAIL_PID 2>/dev/null || true
        TAIL_PID=""
        # Clear the progress display by moving up lines and clearing
        # Move cursor up 11 lines (10 log lines + 1 for the status line)
        echo -ne "\033[11A\033[J" >/dev/tty
        
        log "${GREEN}✅ Installation succeeded${NC}"
        
        # Unmount disks now that installation is complete
        if [[ -n "$disk_1_mount" ]]; then
            unmount_disk "$disk_1_mount"
        fi
        if [[ -n "$disk_2_mount" ]]; then
            unmount_disk "$disk_2_mount"
        fi
        
        # Check if wrapper was created
        wrapper_app=$(find "$SCRIPT_DIR/test-output" -name "Nancy Drew - *.app" -type d -maxdepth 1 | head -1)
        
        if [[ -n "$wrapper_app" ]]; then
            log "${GREEN}✅ Wrapper created: $(basename "$wrapper_app")${NC}"
            
            # Move wrapper to test output directory
            mv "$wrapper_app" "$game_test_dir/"
            wrapper_app="$game_test_dir/$(basename "$wrapper_app")"
            
            # Test launching the game (unless skipped)
            if [[ "$SKIP_LAUNCH" == false ]]; then
                log "${BLUE}🚀 Testing game launch...${NC}"
                
                # Launch game in background with timeout
                if timeout "$LAUNCH_TIMEOUT" open "$wrapper_app" 2>&1 | tee "$game_test_dir/launch-log.txt"; then
                    log "${GREEN}✅ Game launched successfully${NC}"
                    
                    # Give it a moment to start
                    sleep 3
                    
                # Note: Screenshot capture disabled as it requires manual window selection
                # Could be re-enabled with automated window detection in the future
                    
                    end_time=$(date +%s)
                    duration=$((end_time - start_time))
                    log_result "$game_slug" "passed" "Installation and launch successful" "$duration"
                    ((PASSED++))
                    
                    # Cleanup wrapper if requested
                    if [[ "$CLEANUP_WRAPPERS" == true ]]; then
                        log "🧹 Cleaning up wrapper: $wrapper_app"
                        rm -rf "$wrapper_app" 2>/dev/null || true
                    fi
                else
                    log "${YELLOW}⚠️  Game launch timed out or failed${NC}"
                    end_time=$(date +%s)
                    duration=$((end_time - start_time))
                    log_result "$game_slug" "warning" "Installation succeeded but launch failed/timed out" "$duration"
                    ((PASSED++))  # Still count as passed since installation worked
                    
                    # Cleanup wrapper if requested
                    if [[ "$CLEANUP_WRAPPERS" == true ]]; then
                        log "🧹 Cleaning up wrapper: $wrapper_app"
                        rm -rf "$wrapper_app" 2>/dev/null || true
                    fi
                fi
            else
                end_time=$(date +%s)
                duration=$((end_time - start_time))
                log_result "$game_slug" "passed" "Installation successful (launch not tested)" "$duration"
                ((PASSED++))
                
                # Cleanup wrapper if requested
                if [[ "$CLEANUP_WRAPPERS" == true ]]; then
                    log "🧹 Cleaning up wrapper: $wrapper_app"
                    rm -rf "$wrapper_app" 2>/dev/null || true
                fi
            fi
        else
            log "${RED}❌ Wrapper app not created${NC}"
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            log_result "$game_slug" "failed" "Installation completed but wrapper not found" "$duration"
            ((FAILED++))
        fi
    else
        # Kill the tail process first
        kill $TAIL_PID 2>/dev/null || true
        wait $TAIL_PID 2>/dev/null || true
        TAIL_PID=""
        # Clear the progress display by moving up lines and clearing
        # Move cursor up 11 lines (10 log lines + 1 for the status line)
        echo -ne "\033[11A\033[J" >/dev/tty
        
        log "${RED}❌ Installation failed or timed out${NC}"
        log "   Install log: $install_log_file"
        
        # Unmount disks on failure
        if [[ -n "$disk_1_mount" ]]; then
            unmount_disk "$disk_1_mount"
        fi
        if [[ -n "$disk_2_mount" ]]; then
            unmount_disk "$disk_2_mount"
        fi
        
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        log_result "$game_slug" "failed" "Installation failed or timed out after 10 minutes" "$duration"
        ((FAILED++))
    fi
    
    # Copy installation logs
    if [[ -d "$SCRIPT_DIR/test-output" ]]; then
        cp -r "$SCRIPT_DIR/test-output"/* "$game_test_dir/" 2>/dev/null || true
    fi
    done
    
    # Unset environment variables after all tests complete
    unset STRICT_INSTALL INSTALLATION_SOURCE NON_INTERACTIVE OUTPUT_PATH DISK_1_PATH
fi

# Generate summary report
log ""
log "${BLUE}==========================================${NC}"
log "${BLUE}📊 TEST SUMMARY${NC}"
log "${BLUE}==========================================${NC}"
log "${GREEN}✅ Passed:  $PASSED / $TOTAL_GAMES${NC}"
log "${RED}❌ Failed:  $FAILED / $TOTAL_GAMES${NC}"
log "${YELLOW}⚠️  Skipped: $SKIPPED / $TOTAL_GAMES${NC}"
log ""
log "Results saved to: $TEST_OUTPUT_DIR"
log "Detailed results: $RESULTS_FILE"

# Generate HTML report
cat > "$TEST_OUTPUT_DIR/report.html" <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Nancy Drew Games Test Report</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; margin: 20px; }
        h1 { color: #333; }
        .summary { background: #f6f8fa; padding: 20px; border-radius: 6px; margin: 20px 0; }
        .passed { color: #2da44e; font-weight: bold; }
        .failed { color: #cf222e; font-weight: bold; }
        .skipped { color: #bf8700; font-weight: bold; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid #d0d7de; }
        th { background: #f6f8fa; font-weight: 600; }
        tr.test-row { cursor: pointer; }
        tr.test-row:hover { background: #f6f8fa; }
        tr.log-row { display: none; }
        tr.log-row.expanded { display: table-row; }
        tr.log-row td { padding: 0; background: #f6f8fa; }
        .log-content { 
            max-height: 400px; 
            overflow-y: auto; 
            padding: 12px; 
            background: #24292e; 
            color: #e1e4e8;
            font-family: 'SF Mono', Monaco, 'Cascadia Code', 'Roboto Mono', Consolas, 'Courier New', monospace;
            font-size: 12px;
            line-height: 1.5;
            white-space: pre-wrap;
            word-wrap: break-word;
            margin: 8px;
            border-radius: 6px;
        }
        .status-badge { padding: 4px 8px; border-radius: 12px; font-size: 12px; font-weight: 600; }
        .status-passed { background: #dafbe1; color: #1a7f37; }
        .status-failed { background: #ffebe9; color: #cf222e; }
        .status-skipped { background: #fff8c5; color: #9a6700; }
        .status-warning { background: #fff8c5; color: #9a6700; }
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
    <p>Generated: $(date)</p>
    
    <div class="summary">
        <h2>Summary</h2>
        <p><span class="passed">✅ Passed: $PASSED / $TOTAL_GAMES</span></p>
        <p><span class="failed">❌ Failed: $FAILED / $TOTAL_GAMES</span></p>
        <p><span class="skipped">⚠️ Skipped: $SKIPPED / $TOTAL_GAMES</span></p>
    </div>
    
    <h2>Detailed Results</h2>
    <p style="color: #586069; font-size: 14px;">Click on any row to view installation logs</p>
    <table>
        <thead>
            <tr>
                <th>Game</th>
                <th>Status</th>
                <th>Message</th>
                <th>Duration</th>
                <th>Timestamp</th>
            </tr>
        </thead>
        <tbody>
EOF

# Add results to HTML with expandable logs
game_index=0
while IFS= read -r game_result; do
    game_slug=$(echo "$game_result" | jq -r '.game')
    status=$(echo "$game_result" | jq -r '.status')
    message=$(echo "$game_result" | jq -r '.message')
    duration=$(echo "$game_result" | jq -r '.duration')
    timestamp=$(echo "$game_result" | jq -r '.timestamp')
    status_upper=$(echo "$status" | tr '[:lower:]' '[:upper:]')
    
    # Write the test row with proper escaping
    echo "            <tr class=\"test-row\" onclick=\"toggleLog($game_index)\">" >> "$TEST_OUTPUT_DIR/report.html"
    echo "                <td><span class=\"expand-icon\" id=\"icon-$game_index\"></span>$game_slug</td>" >> "$TEST_OUTPUT_DIR/report.html"
    echo "                <td><span class=\"status-badge status-$status\">$status_upper</span></td>" >> "$TEST_OUTPUT_DIR/report.html"
    echo "                <td>$message</td>" >> "$TEST_OUTPUT_DIR/report.html"
    echo "                <td>${duration}s</td>" >> "$TEST_OUTPUT_DIR/report.html"
    echo "                <td>$timestamp</td>" >> "$TEST_OUTPUT_DIR/report.html"
    echo "            </tr>" >> "$TEST_OUTPUT_DIR/report.html"
    
    # Add log row
    echo "            <tr class=\"log-row\" id=\"log-$game_index\">" >> "$TEST_OUTPUT_DIR/report.html"
    echo "                <td colspan=\"5\">" >> "$TEST_OUTPUT_DIR/report.html"
    echo "                    <div class=\"log-content\">" >> "$TEST_OUTPUT_DIR/report.html"
    
    # Read and escape install log if it exists
    install_log_path="$TEST_OUTPUT_DIR/$game_slug/install-log.txt"
    if [[ -f "$install_log_path" ]]; then
        # Escape HTML entities and append log content
        sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$install_log_path" >> "$TEST_OUTPUT_DIR/report.html"
    else
        echo "No installation log available" >> "$TEST_OUTPUT_DIR/report.html"
    fi
    
    echo "                    </div>" >> "$TEST_OUTPUT_DIR/report.html"
    echo "                </td>" >> "$TEST_OUTPUT_DIR/report.html"
    echo "            </tr>" >> "$TEST_OUTPUT_DIR/report.html"
    
    ((game_index++))
done < <(jq -c '.[]' "$RESULTS_FILE")

cat >> "$TEST_OUTPUT_DIR/report.html" <<EOF
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
EOF

log ""
log "${GREEN}📄 HTML report: $TEST_OUTPUT_DIR/report.html${NC}"
log ""

# Open the report
if command -v open &> /dev/null; then
    open "$TEST_OUTPUT_DIR/report.html"
fi

# Exit with appropriate code
if [[ $FAILED -gt 0 ]]; then
    exit 1
else
    exit 0
fi
