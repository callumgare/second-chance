#!/usr/bin/env bash
# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

script_dir=$(dirname "$(readlink -f "$0")")

source "$script_dir/wine-lib.sh"

app_dir="$script_dir/../.."

start_wine_server "$app_dir"
trap 'stop_wine_server "$app_dir"' EXIT

if [ "${1:-}" == "winetricks" ]; then
    shift
    winetricks_url="https://raw.githubusercontent.com/Kegworks-App/winetricks/kegworks/src/winetricks"
    run_with_wine_env_vars "$app_dir" bash -c "curl -sS '$winetricks_url' | bash -s -- "\$@"" -- "$@"
else
    run_with_wine "$app_dir" "$@"
fi
