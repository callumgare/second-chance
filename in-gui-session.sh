#!/bin/bash
# in-gui-session.sh - Run a command in the logged-in user's GUI (Aqua) session
#
# Usage:
#   ./in-gui-session.sh <command> [args...]
#
# Example, from another machine:
#   ssh -t <host> bash -c "'cd ~/tmp/second-chance && ./in-gui-session.sh ./run.sh --game seven-ships --launch-game'"
#
# A shell started over SSH lives in launchd's Background session, which has no
# WindowServer connection. Wine's graphics driver can't load there, so every
# window creation fails — game installers exit 1 and games never appear. This
# script runs the command as a one-off LaunchAgent in gui/<uid> instead, streams
# its output back here, and exits with its exit code.
#
# The command runs in the current directory with the current environment, inside
# a pseudo-terminal so TTY-gated output (LogStore's stderr mirror) still shows.
# Someone must be logged in at the console as the same user. Windows appear on
# that machine's screen.
#
# Already in the GUI session (e.g. local Terminal), the command just runs.

set -euo pipefail

# Snapshot the caller's environment before this script assigns anything: an
# exported variable that shares a name with one below (LABEL, DOMAIN, …) would
# otherwise reach the command with this script's value instead of the caller's.
# Exported readonly variables are skipped — redeclaring them errors.
CALLER_ENV="$(export -p | grep -v '^declare -[a-zA-Z]*r')"

RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <command> [args...]"
    exit 1
fi

if [[ "$(launchctl managername)" == "Aqua" ]]; then
    exec "$@"
fi

CONSOLE_USER="$(stat -f %Su /dev/console)"
if [[ "$CONSOLE_USER" != "$(id -un)" ]]; then
    echo -e "${RED}Error: no GUI session for $(id -un) — the console is owned by '$CONSOLE_USER'.${NC}"
    echo -e "${RED}Log in at the machine (or via Screen Sharing) as $(id -un) first.${NC}"
    exit 1
fi

# A locked screen still has a GUI session, so Wine runs — but synthetic clicks
# land on the lock screen and screenshots don't show the game, so anything
# driven by WrappPuppeteer fails late and confusingly. Refuse up front instead.
if ioreg -n Root -d1 -a | grep -q '<key>CGSSessionScreenIsLocked</key>'; then
    if [[ "${SKIP_LOCK_CHECK:-}" == 1 ]]; then
        echo -e "${RED}Warning: $(id -un)'s screen is locked — running anyway (SKIP_LOCK_CHECK=1).${NC}"
    else
        echo -e "${RED}Error: $(id -un)'s screen is locked.${NC}"
        echo -e "${RED}Unlock it (at the machine or via Screen Sharing) first. Set SKIP_LOCK_CHECK=1 to run anyway.${NC}"
        exit 1
    fi
fi

DOMAIN="gui/$(id -u)"
LABEL="au.gare.callum.second-chance.in-gui-session.$$"
WORK_DIR="$(mktemp -d)"
LOG_FILE="$WORK_DIR/output.log"
EXIT_FILE="$WORK_DIR/exit-code"
JOB_SCRIPT="$WORK_DIR/job.sh"
PLIST="$WORK_DIR/$LABEL.plist"
TAIL_PID=""
# A dropped SSH connection without a pty sends us no signal: sshd-session just
# exits, and the shells between it and us live on, reparented to launchd. So
# remember every ancestor now and treat any of them disappearing as the caller
# being gone.
ANCESTORS=()
pid=$PPID
while [[ "$pid" -gt 1 ]]; do
    ANCESTORS+=("$pid")
    pid="$(ps -o ppid= -p "$pid" | tr -d ' ')"
done

cleanup() {
    trap - EXIT INT TERM HUP
    # Booting out the job kills its whole process group, which stops the
    # command if we're leaving early (Ctrl-C, dropped SSH connection, caller
    # gone).
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    if [[ -n "$TAIL_PID" ]]; then
        kill "$TAIL_PID" 2>/dev/null || true
        wait "$TAIL_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# `script` gives the command a pty. Its stdin is a pipe that never closes — from
# /dev/null, `script` would forward the EOF into the pty and print a stray ^D.
#
# The job script recreates the caller's environment and directory, then runs
# the command.
{
    echo '#!/bin/bash'
    printf '%s\n' "$CALLER_ENV"
    printf 'cd %q || exit 1\n' "$PWD"
    printf '%q ' "$@"
    echo
    printf 'echo $? > %q\n' "$EXIT_FILE"
} > "$JOB_SCRIPT"
chmod +x "$JOB_SCRIPT"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>tail -f /dev/null | /usr/bin/script -q /dev/null "\$0"</string>
        <string>$JOB_SCRIPT</string>
    </array>
    <key>StandardOutPath</key><string>$LOG_FILE</string>
    <key>StandardErrorPath</key><string>$LOG_FILE</string>
    <key>RunAtLoad</key><true/>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF

touch "$LOG_FILE"
echo -e "${BLUE}🖥  Running in $(id -un)'s GUI session: $*${NC}"
launchctl bootstrap "$DOMAIN" "$PLIST"

tail -n +1 -f "$LOG_FILE" &
TAIL_PID=$!

# Wait for the command to finish. If the job dies without writing an exit code
# (killed, or `script` itself failed), launchd drops its PID — stop then too.
while [[ ! -f "$EXIT_FILE" ]]; do
    sleep 1
    # `ps -p`, not `kill -0`: sshd's privileged half is root's, and signalling
    # it fails with EPERM while it's very much alive.
    for pid in "${ANCESTORS[@]}"; do
        ps -p "$pid" > /dev/null || exit 129
    done
    if ! launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q 'pid = '; then
        sleep 1
        break
    fi
done

# Let tail catch up on the last of the output.
sleep 1

if [[ -f "$EXIT_FILE" ]]; then
    EXIT_CODE="$(cat "$EXIT_FILE")"
else
    echo -e "${RED}Error: the command exited without reporting an exit code${NC}"
    EXIT_CODE=1
fi
exit "$EXIT_CODE"
