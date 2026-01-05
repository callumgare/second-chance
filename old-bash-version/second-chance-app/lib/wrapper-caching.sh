#!/usr/bin/env bash
# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -Eeuo pipefail
IFS=$'\n\t'

##########################
# Sourcing Requirements:
#
# The following variables must be at defined before sourcing this script:
debug_mode="${debug_mode:-}"
tmp_dir="${tmp_dir:-}"
tmp_wrapper_path="${tmp_wrapper_path:-}"
##########################


current_script_dir_lib_wrapper_caching=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

executing_in_app_bundle="$(ps -o comm= -p "$(ps -o ppid= -p $$)" | grep -q '.app' && echo "true" || echo "")"

if [ "$executing_in_app_bundle" == "true" ]; then
    # shellcheck source=../../shared/utils.sh
    source "$current_script_dir_lib_wrapper_caching/../shared/utils.sh"
else
    # shellcheck source=../../shared/utils.sh
    source "$current_script_dir_lib_wrapper_caching/../../shared/utils.sh"
fi

dev_cache_wrapper_stage_to_restore="${dev_cache_wrapper_stage_to_restore:-}"

cache_dir="$tmp_dir/wrapper-cache"

cache_stages=(
    "base"
        "disk-game-installer-copied"
            "disk-game-installed"
        "her-download-game-installed"
        "steam-client-installed"
            "steam-client-login"
                "steam-game-installed"
)

all_cache_wrapper_stages_up_to_and_including_last_stages () {
    local last_stages_csv="$1"
    local IFS=','
    local stage
    local last_trimmed
    local max_idx=-1
    local i j
    # Convert comma-separated list to array, trimming spaces
    local last_stages_arr=()
    for stage in $last_stages_csv; do
        stage="$(echo "$stage" | sed 's/^ *//;s/ *$//')"
        last_stages_arr+=("$stage")
    done
    # Find the highest index of any last stage in the list
    for ((i=0; i<${#cache_stages[@]}; i++)); do
        stage="${cache_stages[$i]}"
        for ((j=0; j<${#last_stages_arr[@]}; j++)); do
            last_trimmed="${last_stages_arr[$j]}"
            if [ -n "$last_trimmed" ] && [ "$stage" = "$last_trimmed" ]; then
                if [ $i -gt $max_idx ]; then
                    max_idx=$i
                fi
            fi
        done
    done
    # Output all stages up to and including max_idx
    for ((i=0; i<=max_idx; i++)); do
        printf "%s\n" "${cache_stages[$i]}"
    done
}

is_valid_cache_wrapper_stage () {
    local stage="$1"
    for s in "${cache_stages[@]}"; do
        if [ "$s" = "$stage" ]; then
            return 0
        fi
    done
    return 1
}

should_restore_cached_wrapper () {
    local stage="$1"
    local stages_to_restore
    local s
    if ! is_valid_cache_wrapper_stage $stage; then
        echo "Invalid cache wrapper stage: $stage" >&2
        exit 1
    fi
    stages_to_restore="$(all_cache_wrapper_stages_up_to_and_including_last_stages "$dev_cache_wrapper_stage_to_restore")"
    for s in $stages_to_restore; do
        if [ "$s" = "$stage" ]; then
            return 0
        fi
    done
    return 1
}

attempt_to_restore_cached_wrapper () {
    local stage="$1"
    local cache_path="$cache_dir/$stage"
    if [ "$stage" == "$dev_cache_wrapper_stage_to_restore" ]; then
        if [ -d "$cache_path/wrapper" ]; then
            echo "Restoring cache for: $stage"
            delete_old_wrapper
            cp -ac "$cache_path/wrapper" "$tmp_wrapper_path"
            # Restore any required environment variables
            # shellcheck disable=SC1090 # Env var file is dynamically generated
            source "$cache_path/env_vars"
            return 0
        else
            echo "Tried to restore $stage wrapper cache but no cache found at"
            exit 1
        fi
    elif should_restore_cached_wrapper "$stage"; then
        # Wrapper will be restored in a later stage
        return 0
    fi
    # Return a false value if cache usage was not requested or no cache was found
    return 1
}

save_cached_wrapper_if_requested () {
    local stage=$1
    shift
    local cache_path="$cache_dir/$stage"
    if [ "$debug_mode" != "true" ]; then
        return 0
    fi
    if [ ! -d "$cache_path" ]; then
        local wine_was_running
        wine_was_running=$(wine_is_running "$tmp_wrapper_path" && echo "true" || echo "false")
        if [ "$wine_was_running" == "true" ]; then
            # We to stop the wine server to make sure all registry changes have been writen to disk
            # before attempting to copy the wrapper
            stop_wine_server "$tmp_wrapper_path"
        fi
        mkdir -p "$cache_path"
        cp -ac "$tmp_wrapper_path" "$cache_path/wrapper.tmp" 
        mv "$cache_path/wrapper.tmp" "$cache_path/wrapper"
        # Cache any required environment variables
        printf "%s\n" "$@" > "$cache_path/env_vars"
        if [ "$wine_was_running" == "true" ]; then
            start_wine_server "$tmp_wrapper_path"
        fi
    fi
}