#!/bin/bash
# sc — the Second Chance developer CLI. `./sc --help`, or see docs/dev-cli.md.
#
# This only builds Tools/sc (when its sources have changed, quietly unless the
# build fails) and runs it; everything else lives in the Swift package.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="$root/Tools/sc"
binary="$package/.build/release/sc"
# What the binary was built from, as a hash of the sources' contents:
# everything in Packages/ and Tools/sc but what builds leave, so a package
# sc comes to depend on is covered without a list to keep up (one sc
# doesn't use costs a rebuild that finds nothing to do). Not their
# modification times: `sc --on` syncs with rsync, which keeps the sending
# Mac's times, so a checkout synced over another's (another branch, or an
# older commit) kept the binary built from that one (~50 ms).
stamp="$binary.sources"
files_stamp="$binary.files"
files="$(cd "$root" && find -L Packages Tools/sc \( -name .build -o -name .swiftpm \) -prune -o -type f -not -name .DS_Store \
    -print 2>/dev/null | LC_ALL=C sort)"
sources_hash="$(cd "$root" && printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 shasum | shasum)"
# Which files there are, apart from what's in them: SwiftPM's incremental
# build of a local package can miss a file added to it, and fail as though
# it weren't there, so a file added or removed means a clean build.
files_hash="$(printf '%s\n' "$files" | shasum)"

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
    if [[ "$(cat "$files_stamp" 2>/dev/null)" != "$files_hash" ]]; then
        rm -rf "$package/.build/release" "$package/.build/arm64-apple-macosx/release" "$package/.build/x86_64-apple-macosx/release"
    fi
    status=0
    output="$(swift build -c release --package-path "$package" 2>&1)" || status=$?
    if [[ $status -ne 0 ]]; then
        # Once more from clean, in case the build's own state was what failed.
        rm -rf "$package/.build"
        status=0
        output="$(swift build -c release --package-path "$package" 2>&1)" || status=$?
    fi
    stop_spinner
    trap - INT TERM
    if [[ $status -ne 0 ]]; then
        printf '%s\n' "$output" >&2
        echo "sc: building Tools/sc failed (output above)" >&2
        exit 1
    fi
    printf '%s\n' "$sources_hash" > "$stamp"
    printf '%s\n' "$files_hash" > "$files_stamp"
fi

SC_REPO_ROOT="$root" exec "$binary" "$@"
