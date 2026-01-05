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

current_script_dir_lib_support=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

executing_in_app_bundle="$(ps -o comm= -p "$(ps -o ppid= -p $$)" | grep -q '.app' && echo "true" || echo "")"

if [ "$executing_in_app_bundle" == "true" ]; then
    # shellcheck source=../../shared/applescript.sh
    source "$current_script_dir_lib_support/../shared/applescript.sh"
    # shellcheck source=../../shared/utils.sh
    source "$current_script_dir_lib_support/../shared/utils.sh"
    # shellcheck source=../../shared/wine-lib.sh
    source "$current_script_dir_lib_support/../shared/wine-lib.sh"
else
    # shellcheck source=../../shared/applescript.sh
    source "$current_script_dir_lib_support/../../shared/applescript.sh"
    # shellcheck source=../../shared/utils.sh
    source "$current_script_dir_lib_support/../../shared/utils.sh"
    # shellcheck source=../../shared/wine-lib.sh
    source "$current_script_dir_lib_support/../../shared/wine-lib.sh"
fi


find_game_exe_after_install () {
    set -Eeuo pipefail
    local IFS=$'\n'
    # shellcheck disable=SC2206 # We want quotespliting in this case
    local -a exe_paths_before_install=( $1 )
    # shellcheck disable=SC2206
    local -a exe_paths_after_install=( $2 )
    local expected_game_exe_path=${3}
    local shared_root_path=${4}
    
    local -a new_exe_paths=()
    [ "$debug_mode" == "true" ] && echo "Number of EXEs before install: ${#exe_paths_before_install[@]}" >&2
    [ "$debug_mode" == "true" ] && echo "Number of EXEs after install: ${#exe_paths_after_install[@]}" >&2
    
    # Find all paths that only exist after installer has run and add to new_exe_paths
    for exe_after_install_path in "${exe_paths_after_install[@]+"${exe_paths_after_install[@]}"}"; do
        for exe_before_install_path in "${exe_paths_before_install[@]+"${exe_paths_before_install[@]}"}"; do
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
        # If the filename in the exe path matches the filename of the expected exe path then mark it as the
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
            new_relative_exe_paths+=("${new_exe_path#"${shared_root_path}"}")
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
    local app_path="$1"
    installer_path=$2
    install_count=$3
    setup_iss_path=$4
    
    # windows_installer_path="$(to_windows_path "$app_path" "$installer_path")"
    windows_installer_path="$installer_path"
    
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
                return_as_array start "/wait" "/unix" "$windows_installer_path" "/s" "/sms" "/f1$(to_windows_path "$setup_iss_path")"
            fi
        else
            return_as_array start "/wait" "/unix" "$windows_installer_path" "/r"
        fi
    elif [[ "$installer_type" == "inno-setup" ]]; then
        if [ "$install_count" -eq 0 ]; then
            return_as_array start "/wait" "/unix" "$windows_installer_path" "/verysilent" "/norestart"
        else
            return_as_array start "/wait" "/unix" "$windows_installer_path"
        fi
    else
        return_as_array start "/wait" "/unix" "$windows_installer_path"
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
    "$current_script_dir_lib_support/exiftool/exiftool" "$1"
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