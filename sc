#!/bin/bash
# sc — the Second Chance developer CLI. `./sc --help`, or see docs/dev-cli.md.
#
# This only builds Tools/sc (when its sources have changed, quietly unless the
# build fails) and runs it; everything else lives in the Swift package.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="$root/Tools/sc"
binary="$package/.build/release/sc"

if [[ ! -x "$binary" ]] || [[ -n "$(find -L "$package/Sources" "$package/Package.swift" "$package/Package.resolved" -newer "$binary" -print -quit 2>/dev/null)" ]]; then
    # Rebuilding takes ~10 s (longer the first time), so say so. In a
    # terminal: a spinner with the elapsed time, cleared once it's done.
    message="Building sc (Tools/sc has changed)"
    spinner=""
    if [[ -t 2 ]]; then
        (
            frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
            start=$SECONDS
            i=0
            while :; do
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
    if [[ -n "$spinner" ]]; then
        kill "$spinner" 2>/dev/null
        wait "$spinner" 2>/dev/null || true
        printf '\r\033[K' >&2
    fi
    if [[ $status -ne 0 ]]; then
        printf '%s\n' "$output" >&2
        echo "sc: building Tools/sc failed (output above)" >&2
        exit 1
    fi
    touch "$binary"
fi

SC_REPO_ROOT="$root" exec "$binary" "$@"
