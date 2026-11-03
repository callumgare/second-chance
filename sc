#!/bin/bash
# sc — the Second Chance developer CLI. `./sc --help`, or see docs/dev-cli.md.
#
# This only builds Tools/sc (when its sources have changed, quietly unless the
# build fails) and runs it; everything else lives in the Swift package.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="$root/Tools/sc"
binary="$package/.build/release/sc"
# What the binary was built from, as a hash of the sources' contents: with
# Packages/GameCatalog, the game catalog sc shares with the app, and
# Packages/WrappBuilder, the bundle loading `sc bundle` uses, with the
# WrappKit modules it needs. Not their modification times: `sc --on` syncs
# with rsync, which keeps the sending Mac's times, so a checkout synced over
# another's (another branch, or an older commit) kept the binary built from
# that one (~50 ms).
stamp="$binary.sources"
sources_hash="$(cd "$root" && find -L Tools/sc/Sources Packages/GameCatalog Packages/WrappBuilder/Sources Packages/WrappBuilder/Package.swift \
    Packages/WrappKit/Sources Packages/WrappKit/Package.swift Tools/sc/Package.swift Tools/sc/Package.resolved \
    -type f -not -path '*/.build/*' -not -path '*/.swiftpm/*' -not -name .DS_Store -print0 2>/dev/null \
    | sort -z | xargs -0 shasum | shasum)"

if [[ ! -x "$binary" ]] || [[ "$(cat "$stamp" 2>/dev/null)" != "$sources_hash" ]]; then
    # Rebuilding takes ~10 s (longer the first time), so say so. In a
    # terminal: a spinner with the elapsed time, cleared once it's done.
    message="Building sc (Tools/sc has changed)"
    spinner=""
    stop_spinner() {
        if [[ -n "$spinner" ]]; then
            kill "$spinner" 2>/dev/null || true
            wait "$spinner" 2>/dev/null || true
            spinner=""
            printf '\r\033[K' >&2
        fi
    }
    # ^C, or a kill, stops the spinner along with the build. A background
    # job in a script ignores SIGINT, so on its own it outlived the build and
    # the script, drawing over the shell's prompt.
    trap 'stop_spinner; exit 130' INT
    trap 'stop_spinner; exit 143' TERM
    if [[ -t 2 ]]; then
        (
            frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
            start=$SECONDS
            i=0
            # Until it's stopped, or the script has gone however it went
            # ($$ is the script's PID, here too).
            while kill -0 $$ 2>/dev/null; do
                printf '\r  %s \033[2m%s · %ss\033[0m' "${frames:i++%10:1}" "$message" "$((SECONDS - start))" >&2
                sleep 0.1
            done
        ) &
        spinner=$!
    else
        echo "${message}…" >&2
    fi
    status=0
    output="$(swift build -c release --package-path "$package" 2>&1)" || status=$?
    stop_spinner
    trap - INT TERM
    if [[ $status -ne 0 ]]; then
        printf '%s\n' "$output" >&2
        echo "sc: building Tools/sc failed (output above)" >&2
        exit 1
    fi
    printf '%s\n' "$sources_hash" > "$stamp"
fi

SC_REPO_ROOT="$root" exec "$binary" "$@"
