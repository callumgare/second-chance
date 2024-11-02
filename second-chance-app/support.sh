#!/usr/bin/env bash
# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -Eeuo pipefail
IFS=$'\n\t'

second_chance_app_support_script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

second_chance_app_dir="$second_chance_app_support_script_dir/../.."

debug_mode="${debug_mode:-}"
dev_use_wrapper_cache="${dev_use_wrapper_cache:-}"
tmp_dir="${tmp_dir:-}"
tmp_wrapper_path="${tmp_wrapper_path:-}"

if [ -z "$tmp_dir" ]; then
    echo "Error: tmp_dir is not set" >&2
    exit 1
fi
if [ -z "$tmp_wrapper_path" ]; then
    echo "Error: tmp_wrapper_path is not set" >&2
    exit 1
fi

cache_dir="$tmp_dir/wrapper-cache"

# shellcheck source=../shared/applescript.sh
source "$second_chance_app_support_script_dir/applescript.sh"
# source "$second_chance_app_support_script_dir/../shared/applescript.sh"

# shellcheck source=../shared/utils.sh
source "$second_chance_app_support_script_dir/utils.sh"

# shellcheck source=../shared/wine-lib.sh
source "$second_chance_app_support_script_dir/wine-lib.sh"

find_game_exe_after_install () {
    set -Eeuo pipefail
    local IFS=$'\n'
    # shellcheck disable=SC2206 # We want quotespliting in this case
    local -a local_exe_paths_before_install=( $1 )
    # shellcheck disable=SC2206
    local -a local_exe_paths_after_install=( $2 )
    local expected_game_exe_path=${3}
    local shared_root_path=${4}
    
    local -a new_exe_paths=()
    [ "$debug_mode" == "true" ] && echo "Number of EXEs before install: ${#local_exe_paths_before_install[@]}" >&2
    [ "$debug_mode" == "true" ] && echo "Number of EXEs after install: ${#local_exe_paths_after_install[@]}" >&2
    
    # Find all paths that only exist after installer has run and add to new_exe_paths
    for exe_after_install_path in "${local_exe_paths_after_install[@]+"${local_exe_paths_after_install[@]}"}"; do
        for exe_before_install_path in "${local_exe_paths_before_install[@]+"${local_exe_paths_before_install[@]}"}"; do
            if [ "$exe_after_install_path" == "$exe_before_install_path" ]; then
                [ "$debug_mode" == "true" ] && echo "Exe existed before: $exe_after_install_path" >&2
                continue 2
            fi
        done
        new_exe_paths+=("$exe_after_install_path")
        [ "$debug_mode" == "true" ] && echo "Exe added by installer: $exe_after_install_path" >&2
    done
    
    
    local expected_exe_filename
    expected_exe_filename=$(basename "$expected_game_exe_path")
    expected_exe_filename=${expected_exe_filename:-"game.exe"}
    [ "$debug_mode" == "true" ] && echo "Expected exe filename: $expected_exe_filename" >&2
    
    local default_path_selection=""
    if [ ${#new_exe_paths[@]} -gt 0 ]; then
        for new_exe_path in "${new_exe_paths[@]}"; do
            # If the exe path matches the expected path then return it
            if [ "$new_exe_path" == "$expected_game_exe_path" ]; then
                echo "$new_exe_path"
                [ "$debug_mode" == "true" ] && echo "Exe matched expected: $new_exe_path" >&2
                return
            fi
            # If the original filename (from the file's metadata) is "game.exe" then return the path
            original_file_name="$(get_file_info "$new_exe_path" "Original File Name")"
            [ "$debug_mode" == "true" ] && echo "original file name: $original_file_name" >&2
            if [ "$original_file_name" == "GAME.EXE" ]; then
                echo "$new_exe_path"
                [ "$debug_mode" == "true" ] && echo "Exe matched original file name GAME.EXE: $new_exe_path" >&2
                return
            fi
        done
        # If the fiename in the exe path matches the filename of the expected exe path then mark it as the
        # default selection in the prompt we're about to show to the user
        for new_exe_path in "${new_exe_paths[@]}"; do
            if [[ "$(to_lowercase "$new_exe_path")" == *"$(to_lowercase "$expected_exe_filename")" ]]; then
                default_path_selection="$new_exe_path"
                break
            fi
        done
    fi
    
    [ "$debug_mode" == "true" ] && echo "Default selection: $default_path_selection" >&2
    
    # If we've gotten to this point we haven't found the exe path so we need to ask the user to select it
    if [ ${#new_exe_paths[@]} -gt 0 ]; then
        echo "Select game install location" >&2
        local game_exe_path
        local -a new_relative_exe_paths=()
        for new_exe_path in "${new_exe_paths[@]}"; do
            new_relative_exe_paths+=("$shared_root_path$new_exe_path")
        done
        game_exe_path="$shared_root_path$(
            show_list_select \
                "Could not auto-detect installed game. Please select the game exe or cancel to try installing again:" \
                "default items {\"$default_path_selection\"}" \
                "${new_relative_exe_paths[@]}"
        )"
        if [ -n "$game_exe_path" ]; then
            echo "$game_exe_path"
            [ "$debug_mode" == "true" ] && echo "Exe selected by user: $game_exe_path" >&2
            return
        fi
    fi
                
}


get_installer_args () {
    set -Eeuo pipefail
    installer_dir=$1
    install_count=$2
    setup_iss_path=$3
    
    installer_path=$(get_installer_path "$game_slug" "$installer_dir")
    windows_installer_path="$(to_windows_path "$installer_path")"
    
    local installer_type
    installer_type=$(detect_installer_type "$installer_path")
    
    [ "$debug_mode" == "true" ] && echo "Installer type: $installer_type" >&2
    

    if [[ "$installer_type" == "msi" ]]; then
        if [ "$install_count" -eq 0 ]; then
            return_as_array "msiexec" '/qn' '/l*' 'nancy-drew-install-log.txt' '/i' "$windows_installer_path"
        else
            return_as_array "msiexec" '/i' "$windows_installer_path"
        fi
    elif [[ "$installer_type" == "installshield" ]]; then
        # Even if we have the config for a silent install do a normal install if the silent install failed on the 
        # first attempt
        if  [ -e "$setup_iss_path" ] && [ "$install_count" -eq 0 ]; then
            if [ "$(get_game_info "$game_slug" "use_autoit_for_install")" == "true" ]; then
                return_as_array "C:\\autoit\\AutoIt3.exe" "C:\\installshield-custom-dialog-automate.au3" "$windows_installer_path" "$(get_game_info "$game_slug" "game_title")"
            else
                return_as_array start "/wait" "$windows_installer_path" "/s" "/sms" "/f1$(to_windows_path "$setup_iss_path")"
            fi
        else
            return_as_array start "/wait" "$windows_installer_path" "/r"
        fi
    elif [[ "$installer_type" == "inno-setup" ]]; then
        if [ "$install_count" -eq 0 ]; then
            return_as_array start "/wait" "$windows_installer_path" "/verysilent" "/norestart"
        else
            return_as_array start "/wait" "$windows_installer_path"
        fi
    else
        return_as_array start "/wait" "$windows_installer_path"
    fi
}

is_silent_install () {
    set -Eeuo pipefail
    installer_exe_path=$1
    install_count=$2
    setup_iss_path=$3

    local installer_type
    installer_type=$(detect_installer_type "$installer_path")
    
    echo "setup_iss_path: $setup_iss_path" >&2

    if [ "$install_count" -eq 0 ]; then
        if [[ "$installer_type" == "msi" ]]; then
            echo "true"
        elif [[ "$installer_type" == "inno-setup" ]]; then
            echo "true"
        elif [[ "$installer_type" == "installshield" ]] && [ -e "$setup_iss_path" ]; then
            echo "true"
        else
            echo "false"
        fi
    else
        echo "false"
    fi
}

detect_installer_type () {
    set -Eeuo pipefail
    installer_exe_path=$1

    if [[ "$installer_exe_path" == *".msi" ]]; then
        echo "msi"
        return
    fi
    
    fingerprint="$(get_file_info "$installer_exe_path" "Product Name") $(get_file_info "$installer_exe_path" "Comments")"
    lowercase_fingerprint=$(to_lowercase "$fingerprint")

    [ "$debug_mode" == "true" ] && echo "Installer fingerprint: $fingerprint" >&2
    
    if [[ "$lowercase_fingerprint" == *"installshield"* ]]; then
        echo "installshield"
    elif [[ "$lowercase_fingerprint" == *"inno setup"* ]]; then
        echo "inno-setup"
    else
        echo "unknown"
    fi
    
}

get_installer_path () {
    game_slug=$1
    install_disk_dir=$2
    
    [ "$debug_mode" == "true" ] && echo "Looking for installer in: $install_disk_dir" >&2
    
    # First look for MSI installer file
    installer_path=$(
        find "$install_disk_dir" -iname "*.msi" -maxdepth 1 \( -type f -o -type l \) \
            -print -quit # Only use first result
    )
    if [ -n "$installer_path" ]; then
        echo "$installer_path"
        return
    fi
    
    # Otherwise look for setup.exe file
    installer_path=$(
        find "$install_disk_dir" -iname "setup.exe" -maxdepth 1 \( -type f -o -type l \) \
            -print -quit # Only use first result
    )
    if [ -n "$installer_path" ]; then
        echo "$installer_path"
        return
    fi
    
    # Otherwise look for all exe files and let the user select one
    possible_installer_relative_paths=$(
        find "$install_disk_dir" -iname "*.exe" -maxdepth 1 \( -type f -o -type l \) \
            -exec bash -c 'echo "${1#"$2"}"' -- '{}' "$install_disk_dir/" \; # Return path relative to install_disk_dir
    )
    echo "Possible installer paths: $possible_installer_relative_paths" >&2
    local installer_relative_path=""
    if [ -n "$possible_installer_relative_paths" ]; then
        newline_separated_list_to_array "$possible_installer_relative_paths"
        installer_relative_path=$(
            show_list_select \
                "Could not auto-detect installer. Please select the installer file:" \
                "" \
                "${returned_array[@]}"
        )
    fi

    if [ -n "$installer_relative_path" ]; then
        echo "$install_disk_dir/$installer_relative_path"
    else 
        show_alert "Could not find setup file. Exiting now."
        exit 1
    fi
}

get_all_file_info () {
    [ "$debug_mode" == "true" ] && echo "Getting file info for: $1" >&2
    "$second_chance_app_support_script_dir/exiftool/exiftool" "$1"
}

get_file_info () {
    file_path=$1
    property_name=$2
    get_all_file_info "$file_path" | sed -n -E "s/^$(escape_string_for_sed_regex "$property_name") *: *(.*)/\1/p" || true
}

global_total_progress_steps=0
global_current_step=0

global_output_is_redirected=true

setup_progress_indicator () {
    global_total_progress_steps=$1
}

exec 3>&1 4>&2 

update_progress_indicator () {
    details=$1
    
    ((global_current_step++))
    
    step_number=$global_current_step
    
    percentage=$(echo "scale=2 ; $step_number / $global_total_progress_steps * 100" | bc)

    echo "PROGRESS:$percentage" >&4
    if [ -n "$details" ]; then
        echo "$details" >&3
    fi
    
    exec 1>&3 2>&4
    
    # Prefix each line with progress step details
    exec > >(trap "" INT TERM; sed -u "s/^/$details        technical info: /")
    exec 2> >(trap "" INT TERM; sed -u "s/^/$details        technical info: /" >&2)
}

attempt_to_restore_cached_wrapper () {
    local cache
    cache=$(cached_wrapper_to_use "$@")
    if [ -n "$cache" ]; then
        echo "Restoring cache for: $cache"
        delete_old_wrapper
        cp -ac "$cache_dir/$cache/wrapper" "$tmp_wrapper_path"
        # Restore any required enviromnent variables
        # shellcheck disable=SC1090 # Env var file is dynmically generated
        source "$cache_dir/$cache/env_vars"
        return 0
    fi
    # Return a false value if cache usage was not requested or no cache was found
    false
}

cached_wrapper_to_use () {
    for arg in "$@"; do
        local cache_path="$cache_dir/$arg/wrapper"
        if is_wrapper_caching_requested "$arg" && [ -e "$cache_path" ]; then
            echo "$arg"
            return
        fi
    done
}

is_wrapper_cache_in_use () {
    [ -n "$(cached_wrapper_to_use "$@")" ]
}

is_wrapper_caching_requested () {
    local cache_name=$1
    echo "$dev_use_wrapper_cache" | grep -qE "(?:^|,) *$(escape_string_for_sed_regex "$cache_name") *(?:$|,)"
}

save_cached_wrapper_if_requested () {
    local cache_name=$1
    shift
    local cache_path="$cache_dir/$cache_name"
    if is_wrapper_caching_requested "$cache_name"; then
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