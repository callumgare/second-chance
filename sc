#!/bin/bash
# sc — the Second Chance developer CLI. `./sc --help`, or see docs/dev-cli.md.
#
# This only builds Tools/sc (quietly unless it takes a while or fails) and
# runs it; everything else lives in the Swift package.
set -euo pipefail
# Anything here that fails ends the script (set -e): say that it was sc's own
# set-up, not the command, so a failure never passes for a run that worked.
trap 'echo "sc: getting sc ready failed (line $LINENO, exit $?), so the command didn'"'"'t run." >&2' ERR

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="$root/Tools/sc"
built="$package/.build/release/sc"
# sc runs from a copy, replaced by a rename once a build is done, so a rebuild
# never changes the file a run still in progress was started from, or that it
# copies or re-runs (the keep-alive, a GUI-session re-run, a puppet session).
run="$package/.run"
binary="$run/sc"

# Every run asks SwiftPM, whose incremental build knows what changed: about
# half a second when nothing has. It sees a file synced from another Mac with
# that Mac's older time (it doesn't go by times alone), and files added or
# removed. Concurrent runs queue on SwiftPM's own lock on .build.
#
# The build's output is kept for a failure. Once it's taken 1.5 s (one with
# nothing to do takes ~0.6 s), a spinner says so in a terminal, or a line piped.
message="Building sc"
progress=""
stop_progress() {
    if [[ -n "$progress" ]]; then
        kill "$progress" 2>/dev/null || true
        wait "$progress" 2>/dev/null || true
        progress=""
        [[ -t 2 ]] && printf '\r\033[K' >&2
    fi
    return 0
}
# ^C, or a kill, stops the spinner along with the build. A background job in
# a script ignores SIGINT, so on its own it outlived the build and the
# script, drawing over the shell's prompt.
trap 'stop_progress; exit 130' INT
trap 'stop_progress; exit 143' TERM
(
    sleep 1.5
    if [[ ! -t 2 ]]; then
        echo "${message}…" >&2
        exit 0
    fi
    frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    start=$SECONDS
    i=0
    shown="$message"
    # Until it's stopped, or the script has gone however it went ($$ is the
    # script's PID, here too).
    while kill -0 $$ 2>/dev/null; do
        # Once a second: is SwiftPM waiting for its lock on .build, held by
        # something other than this build (an agent's swift test, an
        # editor)? Then say that, not "Building".
        if (( i % 10 == 0 )); then
            shown="$message"
            holder="$(cat "$package/.build/.lock" 2>/dev/null || true)"
            if [[ "$holder" =~ ^[0-9]+$ ]] && kill -0 "$holder" 2>/dev/null; then
                ours="" pid="$holder"
                for _ in 1 2 3 4 5; do
                    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
                    [[ -z "$pid" || "$pid" == 1 ]] && break
                    [[ "$pid" == "$$" ]] && { ours=1; break; }
                done
                if [[ -z "$ours" ]]; then
                    name="$(basename "$(ps -o comm= -p "$holder" 2>/dev/null)")"
                    shown="Waiting for ${name:-another program} (pid $holder) to finish with Tools/sc/.build"
                fi
            fi
        fi
        printf '\r\033[K  %s \033[2m%s · %ss\033[0m' "${frames:i++%10:1}" "$shown" "$((SECONDS - start))" >&2
        sleep 0.1
    done
) &
progress=$!

# Optimised file by file rather than as a whole module, so a change to one
# file rebuilds that file: ~25 s after a one-line change against ~2 min,
# under load, and sc runs as fast.
status=0
output="$(swift build -c release -Xswiftc -no-whole-module-optimization --package-path "$package" 2>&1)" || status=$?
stop_progress
trap - INT TERM
if [[ $status -ne 0 ]]; then
    printf '%s\n' "$output" >&2
    echo "sc: building Tools/sc failed (output above). If it's the build's own state that's broken, not the code: rm -rf Tools/sc/.build" >&2
    exit 1
fi

# A new copy only when SwiftPM made a new binary. Each run copies to a name of
# its own, so two at once can't trip over each other.
if [[ ! -x "$binary" || "$built" -nt "$binary" ]]; then
    mkdir -p "$run"
    cp "$built" "$binary.new.$$"
    mv -f "$binary.new.$$" "$binary"
fi

SC_REPO_ROOT="$root" exec "$binary" "$@"
