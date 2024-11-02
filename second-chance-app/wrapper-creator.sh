#!/usr/bin/env bash
# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -Eeuo pipefail
IFS=$'\n\t'


# if [ "$debug_mode" == "true" ]; then
#     set -x
# fi

script_dir=$(dirname "$(readlink -f "$0")")


# shellcheck source=../shared/utils.sh
source "$script_dir/utils.sh"

# shellcheck source=../shared/wine-lib.sh
source "$script_dir/wine-lib.sh"

# shellcheck source=./game-titles-info.sh
source "$script_dir/game-titles-info.sh"

# shellcheck source=../shared/applescript.sh
source "$script_dir/applescript.sh"

tmp_dir="${dev_tmp_dir:-"/tmp/nancy-drew-second-chance"}"

mkdir -p "$tmp_dir"

init_wrapper_filename="nancy-drew-wrapper.app"
zipped_tmp_wrapper_path="$script_dir/nancy-drew-wrapper.zip"

tmp_wrapper_path="$tmp_dir/$init_wrapper_filename"

tmp_wrapper_drive_c_path="$tmp_wrapper_path/Contents/SharedSupport/prefix/drive_c"

tmp_wrapper_installer_files_dir="$tmp_wrapper_drive_c_path/nancy-drew-installer"
tmp_wrapper_disk_1_destination_path="$tmp_wrapper_installer_files_dir/disk-1"
tmp_wrapper_disk_2_destination_path="$tmp_wrapper_installer_files_dir/disk-2"
tmp_wrapper_disk_combined_destination_path="$tmp_wrapper_installer_files_dir/disk-combined"
tmp_wrapper_setup_iss_path="$tmp_wrapper_installer_files_dir/setup.iss"


tmp_wrapper_setting_plist_path="$tmp_wrapper_path/Contents/Resources/AppSettings.plist"
tmp_wrapper_info_plist_path="$tmp_wrapper_path/Contents/Info.plist"

install_action="${install_action:-}"
possible_disk_1_path="${disk_1_path:-}"
disk_2_path="${disk_2_path:-}"
dev_installer_answer_files_dir="${dev_installer_answer_files_dir:-}"
dev_lower_case_fingerprints_info_path="${dev_game_titles_info_path:-}"
app_save_dir="${app_save_dir:-}"
override_existing="${override_existing:-}"
post_creation_action="${post_creation_action:-}"
debug_mode="${debug_mode:-}"
dev_use_wrapper_cache="${dev_use_wrapper_cache:-}"
dev_unmount_source_disks="${dev_unmount_source_disks:-}"

primary_install_disk_dir="$tmp_wrapper_disk_1_destination_path"

# shellcheck source=./support.sh
source "$script_dir/support.sh"

main () {
    set -Eeuo pipefail
    local game_exe_path=""
    local game_engine=""
    
    echo "PROGRESS:0" >&4
    if [ "$debug_mode" != "true" ]; then
        echo "DETAILS:HIDE" >&4
    fi
    
    
    if [ -z "$install_action" ]; then
        install_action_button=$(
            show_button_select_dialog \
                'Welcome Detective!'$'\n\n'$'Second Chance allows you to run Nancy Drew games on a Mac. Before we begin you will need to own a copy of the Nancy Drew game that you would like to play. This can be via the original game CDs or from Steam. Which would you like to use to install the game?' \
                'cancel button "Cancel"' \
                "Cancel" "Steam" "Game Disk(s)"
        )
        if [ "$install_action_button" == "Game Disk(s)" ]; then
            install_action="disk"
        elif [ "$install_action_button" == "Steam" ]; then
            install_action="steam"
        fi
    fi
    echo "Using install action: $install_action"

    if [ "$install_action" == "disk" ]; then
        setup_progress_indicator 7
        
        update_progress_indicator "Gathering info..."

        ##########################################
        # Get first disk location and detect game title
        ##########################################
        disk_1_path=""
        while [ -z "$disk_1_path" ]; do
            if [ -z "$possible_disk_1_path" ]; then
                possible_disk_1_path=$(
                    show_folder_selection_dialog \
                        "Please select the installer disk (disk 1 if there are multiple):" \
                        'default location "/Volumes"'
                )
            fi
            path_is_install_disk "$possible_disk_1_path"
            if [ "$(path_is_install_disk "$possible_disk_1_path")" != "true" ]; then
                action=$(
                    show_button_select_dialog \
                        "The selected folder does not appear to be a valid game disk. Please try again." \
                        'default button "Try Again" cancel button "Cancel"' \
                        "Cancel" "Use Anyway" "Try Again" 
                )
                if [ "$action" == "Try Again" ]; then
                    continue
                fi
            fi
            disk_1_path="$possible_disk_1_path"
        done
        
        # Attempt to gather the game info before we copy in the game installer so that we know if
        # there are any issues detecting the game info as soon as possible in the process.
        echo "Detecting game title..."
        game_slug=$(detect_game_slug "disk" "$disk_1_path")
        echo "Detected game: $game_slug"
        
        disk_count=$(get_game_info "$game_slug" "disk_count")
        echo "Detected disk count: $disk_count"
        
        game_engine=$(get_game_info "$game_slug" "game_engine_to_use" "wine")
        echo "Detected game engine: $game_engine"
        
        update_progress_indicator "Setting up wrapper"
        cached_wrapper_game_title=""
        if ! attempt_to_restore_cached_wrapper "game-installer-copied" "base"; then
            ##########################################
            # Create empty wrapper
            ##########################################
            setup_base_wrapper_app
            save_cached_wrapper_if_requested "base"
        fi
        
        update_progress_indicator "Copying in game installer"
        if ! is_wrapper_cache_in_use "game-installer-copied"; then
            ##########################################
            # Copy in disks
            ##########################################
            mkdir -p "$tmp_wrapper_disk_1_destination_path"
            rsync -rltDv "$disk_1_path" "$tmp_wrapper_disk_1_destination_path"
    
            if ! [[ $disk_count =~ ^[0-9]+$ ]]; then
                response=$(
                    show_button_select_dialog \
                        "Could not detect the number of installation disks. Is there a second disk?" \
                        'cancel button "Cancel"' \
                        "Cancel" "Yes" "No"
                )
                if [ "$response" == "Yes" ]; then
                    disk_count=2
                else
                    disk_count=1
                fi
                save_game_info_if_dev_run "$game_slug" "disk_count" "$disk_count"
            fi
        
            if [ "$disk_count" -ge 2 ]; then
                if [ -z "$disk_2_path" ]; then
                    disk_2_path=$(
                        show_folder_selection_dialog \
                            "Please select the second disk:" \
                            'default location "/Volumes"'
                    )
                fi
                mkdir -p "$tmp_wrapper_disk_2_destination_path"
                rsync -rltDv "$disk_2_path" "$tmp_wrapper_disk_2_destination_path"
                
                # Create combined disk folder
                mkdir -p "$tmp_wrapper_disk_combined_destination_path"
                # Create symlinks to each file in disk_1
                # set current working dir to disk so that find outputs relative paths to ensure
                # the symlinks are relative
                pushd "$tmp_wrapper_disk_1_destination_path"
                find . -maxdepth 1 -exec ln -s "../disk-1/{}" "$tmp_wrapper_disk_combined_destination_path" \;
                popd
                pushd "$tmp_wrapper_disk_2_destination_path" 
                find . -maxdepth 1 -exec ln -s "../disk-2/{}" "$tmp_wrapper_disk_combined_destination_path" \;
                popd
                primary_install_disk_dir="$tmp_wrapper_disk_combined_destination_path"
            fi
            
            save_cached_wrapper_if_requested "game-installer-copied" "cached_wrapper_game_title=\"$game_slug\""
        else
            if [ "$game_slug" != "$cached_wrapper_game_title" ]; then
                show_alert \
                    "The game title detected does not match the game title of the cached wrapper. Either use the  same disks as cached in the wrapper or delete the cache."
                exit 1
            fi
        fi

        # if [ "$dev_unmount_source_disks" == "true" ]; then
        #     echo "Unmounting source disks"
        #     hdiutil detach "$disk_1_path"
        #     if [[ -n "$disk_2_path" ]]; then
        #         hdiutil detach "$disk_2_path"
        #     fi
        # fi
        
        update_progress_indicator "Preparing to run game installer"
        
        if [ "$game_engine" == "scummvm" ]; then
            install_scummvm
        elif [ "$game_engine" == "wine" ]; then
            echo "Disk count: $disk_count"
            # Set register disk dirs as CD drives
            for ((i = 1; i <= disk_count; i++)); do
                echo "Setting up install disk-$i dir as CD drive"
                # shellcheck disable=SC2004 # Seems to be shellcheck misunderstanding the situation
                set -x
                letter=$(get_letter_from_number "$(($i + 3))") # Start at "d:"
                mount_dir_into_wine_env "$tmp_wrapper_path" "../drive_c/nancy-drew-installer/disk-$i" "$letter" "cdrom"
                set +x
            done
        fi
        
        ##########################################
        # Run game installer if running with wine
        ##########################################
        possible_setup_iss_path="$script_dir/../Resources/installer-answer-files/$game_slug.iss"
        if [ -e "$possible_setup_iss_path" ]; then
            cp "$possible_setup_iss_path" "$tmp_wrapper_setup_iss_path"
        fi
        
        if [ "$(get_game_info "$game_slug" "use_autoit_for_install")" == "true" ]; then
            cp -ac "$script_dir/../Resources/autoit" \
                "$script_dir/../Resources/installshield-custom-dialog-automate.au3" \
                "$tmp_wrapper_drive_c_path"
        fi
        
        exe_paths_before_install="$(find "$tmp_wrapper_drive_c_path" -iname '*.exe')"
        
        local install_count=0
        local internal_expected_game_exe_path
        internal_expected_game_exe_path=$(get_game_info "$game_slug" "game_exe_path")
        if [ -n "$internal_expected_game_exe_path" ]; then
            game_exe_path="$tmp_wrapper_drive_c_path$internal_expected_game_exe_path"
        fi
        
        # Repeatedly attempt to run installer until game exe is found
        update_progress_indicator "Game installing"
        while [ "$game_engine" == "wine" ] && ! [ -f "$game_exe_path" ]; do
            installer_path=$(get_installer_path "$game_slug" "$primary_install_disk_dir")
            
            if [ "$(is_silent_install "$installer_path" "$install_count" "$tmp_wrapper_setup_iss_path")" == "false" ]; then
                echo "Showing install info"
                install_instructions=$(get_install_instructions "$game_slug")

                if ! [ $install_count -eq 0 ]; then
                    failed_install_info=$(get_failed_install_info "$game_slug")
                    install_instructions="$failed_install_info"$'\n'""$'\n'"$install_instructions"
                else
                    install_instructions="The next step is to run the original game installer. $install_instructions"
                fi
            
                show_button_select_dialog \
                    "$install_instructions" \
                    'cancel button "Cancel"' \
                    "Cancel" "I Understand"
            fi
            
            
            get_installer_args \
                "$installer_path" \
                "$install_count" \
                "$tmp_wrapper_setup_iss_path"
            installer_args=( "${returned_array[@]}" )
        
            # Run the installer
            run_with_wine "$tmp_wrapper_path" "${installer_args[@]}" || echo "Installer returned with non-zero exit code: $?" >&2
            
            
            # Locate game exe after install
            exe_paths_after_install="$(find "$tmp_wrapper_drive_c_path" -iname '*.exe')"
            game_exe_path=$(
                find_game_exe_after_install \
                    "$exe_paths_before_install" \
                    "$exe_paths_after_install" \
                    "$game_exe_path" \
                    "$tmp_wrapper_drive_c_path"
            )
            if [ -n "$game_exe_path" ]; then
                save_game_info_if_dev_run \
                    "$game_slug" \
                    "internal_game_exe_path" \
                    "${game_exe_path#"$tmp_wrapper_drive_c_path"}"
                # Game exe found so end install loop
                break
            fi
            
            install_count=$((install_count + 1))
        done
        
        # Delete autoit program to reduce app size
        rm -rf "$tmp_wrapper_path/Contents/SharedSupport/prefix/drive_c/autoit"
        
        # Copy installer answer file out of wrapper for future use if requested
        init_setup_iss_path="$tmp_wrapper_path/Contents/SharedSupport/prefix/drive_c/windows/setup.iss"
        if [ -e "$init_setup_iss_path" ] && [ -n "$dev_installer_answer_files_dir" ]; then
            local dev_installer_answer_file_path="$dev_installer_answer_files_dir/$game_slug.iss"
            if ! [ -e "$dev_installer_answer_file_path" ]; then
                cp "$init_setup_iss_path" "$dev_installer_answer_file_path"
            fi
        fi
        
        update_progress_indicator "Saving new app"
        
    elif [ "$install_action" == "steam" ]; then
        echo "Installing from Steam"
        
        setup_progress_indicator 4
        update_progress_indicator "Setting up wrapper"

        if ! attempt_to_restore_cached_wrapper "steam-game-installed" "steam-client-setup" "steam-client-installed" "base"; then
            setup_base_wrapper_app
            save_cached_wrapper_if_requested "base"
        fi
        
        if ! is_wrapper_cache_in_use "steam-game-installed" "steam-client-setup" "steam-client-installed"; then
            install_winetrick steam
            save_cached_wrapper_if_requested "steam-client-installed"
        fi
            
        steam_common_apps_path="$tmp_wrapper_drive_c_path/Program Files (x86)/Steam/steamapps/common"
        
        # For some weird reason steam often won't full download a game if esync/msync is enabled
        # See: https://www.reddit.com/r/macgaming/comments/187ntsl/cannot_download_steam_games_on_either_crossover/
        export WINEESYNC=0
        export WINEMSYNC=0
        
        # This step is not normally used but to speed up the testing loop when developing the optional caching
        # of logging into the steam client so that wee don't have to do it every time we re-install a game from steam.
        if is_wrapper_caching_requested "steam-client-setup"; then
            if ! is_wrapper_cache_in_use "steam-game-installed" "steam-client-setup"; then
                # Steam in wine is currently a little broken and on the first run after installation the
                # started process quits before steam is fully started. However a background process continues 
                # and eventually steam does start. This makes it tricky for us to know when steam has 
                # actually closed since we can't simply wait for the process we started to exit. To do deal
                # with this we instead have the wine server started implicitly which will mean our wine 
                # command will only only finish when there are no more wine processes running rather than
                # just when the process we started ends.
                stop_wine_server "$tmp_wrapper_path"
                while ! [ -e "$tmp_wrapper_drive_c_path/Program Files (x86)/Steam/userdata" ]; do
                    show_alert \
                        "[DEV STEP] Steam will now start (it may take a few minutes to open after updating). Please login then quit the Steam app." \
                        'default button "I Understand" cancel button "Cancel"' \
                        "Cancel" "I Understand"
                    # https://web.archive.org/web/20240629222839/https://github.com/Gcenx/WineskinServer/wiki#steam
                    run_with_wine "$tmp_wrapper_path" "C:\Program Files (x86)\Steam\Steam.exe" "-cef-in-process-gpu" "-cef-disable-sandbox" "-cef-disable-gpu" "-nofriendsui" || echo "Installer returned with non-zero exit code: $?" >&2
                    date
                    echo "Steam has closed"
                done;
                echo "Finished logging into Steam"
                start_wine_server "$tmp_wrapper_path"
                
                save_cached_wrapper_if_requested "steam-client-setup"
            fi
        fi

        if ! is_wrapper_cache_in_use "steam-game-installed"; then
            show_button_select_dialog \
                "Steam will now start (please be patient, it may take a few minutes to open after running an update). Please install your desired Nancy Drew title then fully quit Steam (without launching the game first)." \
                'default button "I Understand" cancel button "Cancel"' \
                "Cancel" "I Understand"
        
            update_progress_indicator "Game install (fully quit steam app once the game is installed)"

            # Steam in wine is currently a little broken and on the first run after installation the
            # started process quits before steam is fully started. However a background process continues 
            # and eventually steam does start. This makes it tricky for us to know when steam has 
            # actually closed since we can't simply wait for the process we started to exit. To do deal
            # with this we instead have the wine server started implicitly which will mean our wine 
            # command will only only finish when there are no more wine processes running rather than
            # just when the process we started ends.
            stop_wine_server "$tmp_wrapper_path"

            game_exe_path=""
            while [ -z "$game_exe_path" ]; do
                # https://web.archive.org/web/20240629222839/https://github.com/Gcenx/WineskinServer/wiki#steam
                run_with_wine "$tmp_wrapper_path" "C:\Program Files (x86)\Steam\Steam.exe" "-cef-in-process-gpu" "-cef-disable-sandbox" "-cef-disable-gpu" "-nofriendsui" || echo "Installer returned with non-zero exit code: $?" >&2
            
                # Locate game exe after install
                installed_steam_apps_path="$steam_common_apps_path"
                exe_paths_after_install="$(
                    [ -e "$installed_steam_apps_path" ] && find "$installed_steam_apps_path" -iname '*.exe' || echo ""
                )"
                game_exe_path=$(
                    find_game_exe_after_install \
                        "" \
                        "$exe_paths_after_install" \
                        "" \
                        "$tmp_wrapper_drive_c_path"
                )

                if [ -z "$game_exe_path" ]; then
                    action=$(
                        show_button_select_dialog \
                            "Could not find installed game. You can try installing the game again or you can start Steam every time you launch the app (slower)." \
                            'default button "Try Again" cancel button "Cancel"' \
                            "Cancel" "Try Again"
                    )
                else
                    echo "Game exe path: $game_exe_path"
                fi
            done

            save_cached_wrapper_if_requested "steam-game-installed" "game_exe_path=\"$game_exe_path\""
            
            start_wine_server "$tmp_wrapper_path"
        else
            # To ensure the same number of progress steps are taken
            update_progress_indicator ""
        fi

        unset WINEESYNC
        unset WINEMSYNC
        
        update_progress_indicator "Saving new app"
        
        game_slug=$(detect_game_slug "steam" "$game_exe_path")
        echo "Detected game slug: $game_slug"
        
        game_dir_name=$(echo "${game_exe_path#"$steam_common_apps_path"}" | awk -F'/' '{print $2}')
        steam_id=$(
            grep "\\$game_dir_name" "$tmp_wrapper_drive_c_path/Program Files (x86)/Steam/logs/content_log.txt" \
                | sed -E 's/.*AppID ([0-9]+) .*/\1/'
        )
        
        echo "Detected Steam ID: $steam_id"

        has_steam_drm="$(get_game_info "$game_slug" "has_steam_drm")"
        if [ "$has_steam_drm" == "yes-launch-when-steam-running" ]; then
            # If we're sure the game does have drm then we need to start steam to run the game which
            # we start in silent mode. If the game doesn't have drm but we were to try and run steam
            # in silent mode anyway the game won't start properly (not sure why, seems like a weird 
            # steam bug)
            game_engine="wine-steam-silent"
        elif [ "$has_steam_drm" == "no" ]; then
            # If we're sure the game doesn't have drm then we don't need bother start steam and can 
            # run directly (if it has drm running it directly will fail)
            game_engine="wine"
        else
            if [ -z "$steam_id" ]; then
                echo "Error: Could not detect Steam ID for the game." >&2
                exit 1
            fi
            # Starting steam not in silent mode is the safest bet if we don't know the drm status
            # since this method will work for both drm and non-drm games.
            game_engine=wine-steam
        fi
        
        # Steam attempts to access the microphone so set an appropriate message to inlude in the 
        # mic access permission dialog when it is shown to the user.
        plutil -replace "NSMicrophoneUsageDescription" \
            -string "Steam requires access to the Microphone" \
            "$tmp_wrapper_path/Contents/Info.plist"
    fi
    
    stop_wine_server "$tmp_wrapper_path"

        
    ##########################################
    # Save config details into wrapper
    ##########################################
        
    # Set game to LCD mode if supported
    find "$(dirname "$game_exe_path")" -iname "*.ini" -maxdepth 1 -exec sed -i '' 's/WindowMode=0/WindowMode=2/g' '{}' ';'
    
    # Set game to save in Documents folder
    find "$(dirname "$game_exe_path")" -iname "*.ini" -maxdepth 1 -exec sed -i '' 's|LoadSavePath=.*|LoadSavePath=\\users\\wine\\Documents|g' '{}' ';'

    game_exe_internal_path="${game_exe_path#"$tmp_wrapper_drive_c_path"}"

    plutil -replace "Program Name and Path" -string "$game_exe_internal_path" "$tmp_wrapper_path/Contents/Info.plist"

    plutil -replace "GameExePath" -string "$game_exe_internal_path" "$tmp_wrapper_setting_plist_path"
    plutil -replace "GameInstallerDir" -string "$(remove_prefix "$primary_install_disk_dir" "$tmp_wrapper_drive_c_path")" "$tmp_wrapper_setting_plist_path"
    plutil -replace "GameEngine" -string "$game_engine" "$tmp_wrapper_setting_plist_path"
    
    if [ -n "$steam_id" ]; then
        plutil -replace "SteamGameId" -string "$steam_id" "$tmp_wrapper_setting_plist_path"
    fi

    new_wrapper_bundle_id="$(plutil -extract "CFBundleIdentifier" raw "$tmp_wrapper_info_plist_path").$game_slug"
    new_wrapper_bundle_id_randomised="$new_wrapper_bundle_id.$((RANDOM % 100000))"
    
    # Randomise bundle id to avoid conflicts with other wrappers
    plutil -replace "CFBundleIdentifier" -string "$new_wrapper_bundle_id_randomised" "$tmp_wrapper_info_plist_path"
    # Sometimes we want to share resources between what are different game wrappers but which are for the same game title.
    # For example save files
    plutil -replace "CFBundleIdentifierForGameTitle" -string "$new_wrapper_bundle_id" "$tmp_wrapper_info_plist_path"
        
    ##########################################
    # Get save location
    ##########################################
    if [ -z "$app_save_dir" ]; then
        show_button_select_dialog \
            "Wrapper app has been created. Please choose a location to save it." \
            'default button "Choose Save Location" cancel button "Cancel"' \
            "Cancel" "Choose Save Location"
        app_save_dir=$(
            show_folder_selection_dialog \
                "Please the location to save the app:" \
                'default location "/Applications"'
        )
    fi
    app_save_dir="${app_save_dir%/}" # Remove trailing slash if present
    if [ "$game_slug" != "unknown" ]; then
        app_name="Nancy Drew - $(get_game_info "$game_slug" "game_title")"
    else
        app_name=$(
            show_text_selection_dialog \
                "Please choose a name for the newly created app:" \
                "Nancy Drew" \
                'cancel button "Cancel"' \
                "Cancel" "Save"
        )
    fi
    plutil -replace "CFBundleName" -string "$app_name" "$tmp_wrapper_info_plist_path"
    plutil -replace "CFBundleDisplayName" -string "$app_name" "$tmp_wrapper_info_plist_path"
        
    ##########################################
    # Sign app
    ##########################################
    # App must be fully signed for microphone access to be granted which is required by steam
    if which -s codesign; then
        codesign --remove-signature "$tmp_wrapper_path"
        find "$tmp_wrapper_path/Contents/Frameworks" -type f -exec codesign -s - '{}' ';'
        codesign -s - "$tmp_wrapper_path"
    fi
    
    ##########################################
    # Move wrapper to save location
    ##########################################
    destination_app_path="$app_save_dir/$app_name.app"
    if [ -e "$destination_app_path" ] && [ "$override_existing" == "true" ]; then
        rm -rf "$destination_app_path"
    fi
    while [ -e "$destination_app_path" ]; do
        app_name=$(
            show_text_selection_dialog \
                "An app with the name \"$app_name\" already exists in \"$app_save_dir\". Please choose a different name:" \
                "$app_name (new)" \
                'default button "Save" cancel button "Cancel"' \
                "Cancel" "Save"
        )
        destination_app_path="$app_save_dir/$app_name.app"
    done
    mv "$tmp_wrapper_path" "$destination_app_path"
        
    update_progress_indicator "Finished creating game"
    

    ##########################################
    # Show game created message
    ##########################################
    if [ -z "$post_creation_action" ]; then
        post_creation_action=$(
            show_button_select_dialog \
                "Game app created! What do you want to do now?" \
                'cancel button "Nothing"' \
                "Nothing" "Show in Finder" "Play Now"
        )
    fi
    if [ "$post_creation_action" == "Show in Finder" ]; then
        open -R "$destination_app_path"
    elif [ "$post_creation_action" == "Play Now" ]; then
        open "$destination_app_path"
    fi
    
    if [ "$debug_mode" == "true" ] && [ "$global_current_step" != "$global_total_progress_steps" ]; then
        show_alert "Final progress step number $global_current_step is but step total is $global_total_progress_steps"
    fi
    
    echo "QUITAPP" >&4
}

path_is_install_disk () {
    possible_install_disk_path=$1
    if [ -e "$possible_install_disk_path/Nancy.cid" ] || \
        [ -e "$possible_install_disk_path/Setup.exe" ] || \
        [ -e "$possible_install_disk_path/setup.exe" ] || \
        [ -e "$possible_install_disk_path/Haunting of Castle Malloy.exe" ]; then
        echo "true"
    else
        echo "false"
    fi
}

get_install_instructions () {
    game_slug=$1
    install_instructions=$(
        get_game_info "$game_slug" "install_instructions" "$(get_game_info "unknown" "install_instructions")"
    )
    echo "To successfully install the game you must follow these instructions once the installer has started:"
    echo ""
    echo "$install_instructions"
    echo ""
    echo "If you get lost at any point simply cancel the install and the above instructions will be shown again."
}

get_failed_install_info () {
    game_slug=$1
    echo "Error: installed game could not be found."
    get_game_info "$game_slug" "failed_install_info"
}

delete_old_wrapper () {
    if [ -d "$tmp_wrapper_path" ]; then
        rm -rf "$tmp_wrapper_path"
    fi
}

cleanup () {
    # update_progress_indicator "Exiting"
    if [ -e "$tmp_wrapper_path" ]; then
        stop_wine_server "$tmp_wrapper_path"
    fi
    if [ "$debug_mode" != "true" ]; then
        delete_old_wrapper
    fi
}

install_winetrick () {
    local winetrick_name=$1
    local winetricks_path="$script_dir/../Resources/winetricks"
    
    echo "Installing winetrick $winetrick_name"
    run_with_wine_env_vars "$tmp_wrapper_path" "$winetricks_path" --unattended "$winetrick_name"
}

setup_base_wrapper_app () {
    delete_old_wrapper

    unzip -o "$zipped_tmp_wrapper_path" -d "$tmp_dir"
    echo "Creating prefix"
    create_wine_prefix "$tmp_wrapper_path"
    echo "Starting wine server"
    start_wine_server "$tmp_wrapper_path"
    
    echo "Installing cnc-ddraw"
    install_winetrick cnc_ddraw
    sed -I '' 's/maintas=false/maintas=true/g' "$tmp_wrapper_path/Contents/SharedSupport/prefix/drive_c/windows/syswow64/ddraw.ini"

    install_winetrick sandbox
    # sandbox only removes the main host system drive and symlinks to that drive that are added to drive_c
    # so we remove all non c drive drives
    rm "$tmp_wrapper_path/Contents/SharedSupport/prefix/dosdevices/"*
    ln -s "../drive_c" "$tmp_wrapper_path/Contents/SharedSupport/prefix/dosdevices/c:"
    # Slightly ugly hack to stop wine from mounting in other host system drives by creating dummy files
    # for each drive letter
    for letter in {d..z}; do
        touch "$tmp_wrapper_path/Contents/SharedSupport/prefix/dosdevices/$letter:"
    done
}

install_scummvm () {
    cp -r "$second_chance_app_support_script_dir/scummvm/Frameworks/"* "$tmp_wrapper_path/Contents/Frameworks"
    cp -r "$second_chance_app_support_script_dir/scummvm/Resources/"* "$tmp_wrapper_path/Contents/Resources"
}

get_game_info () {
    game_slug=$1
    info_key=$2
    default_value=${3:-}
    var_name=$(echo "$game_slug" | tr '-' '_')"__$info_key"
    echo "${!var_name:-$default_value}"
}

save_game_info_if_dev_run () {
    game_slug=$1
    key=$2
    value=$3
    
    var_name="${game_slug//-/_}__${key}"
    
    if [ -n "$dev_lower_case_fingerprints_info_path" ] && [ -z "${!var_name+fallback}" ] && [ "$game_slug" != "unknown" ]; then
        echo -e "\n${var_name}=\"$value\"" >> "$dev_lower_case_fingerprints_info_path"
    fi
}

detect_game_slug () {
    set -Eeuo pipefail
    local install_type=$1
    local fingerprint=""
    if [ "$install_type" == "disk" ]; then
        local install_disk_path=$2
        
        local setup_exe_path
        setup_exe_path=$(
            find "$install_disk_path" -iname "setup.exe" -maxdepth 1 \( -type f -o -type l \) -print -quit
        )
        if [ -f "$setup_exe_path" ]; then
            fingerprint=$(get_file_info "$setup_exe_path" "Product Name")
        fi
        
        local msi_path
        msi_path=$(find "$install_disk_path" -iname "*.msi" -maxdepth 1 \( -type f -o -type l \) -print -quit)
        if [ -f "$msi_path" ]; then
            fingerprint=$(get_file_info "$msi_path" "Subject")
        fi
        
        local setup_ini_path
        setup_ini_path=$(
            find "$install_disk_path" -iname "setup.ini" -maxdepth 1 \( -type f -o -type l \) -print -quit
        )
        if [ -f "$setup_ini_path" ]; then
            [ "$debug_mode" == true ] && echo "setup_ini_path: $setup_ini_path" >&2
            fingerprint="$fingerprint $(
                get_property_from_ini "$setup_ini_path" "AppName"
            )"
            fingerprint="$fingerprint $(
                get_property_from_ini "$setup_ini_path" "Product" 
            )"
        fi
        
        local autorun_inf_path
        autorun_inf_path=$(
            find "$install_disk_path" -iname "autorun.inf" -maxdepth 1 \( -type f -o -type l \) -print -quit
        )
        [ "$debug_mode" == true ] && echo "autorun_inf_path: $autorun_inf_path" >&2
        if [ -f "$autorun_inf_path" ]; then
            [ "$debug_mode" == true ] && echo "autorun_inf_path: $autorun_inf_path" >&2
            # MacOS sed does not support "\r" usage in charecter classes so use a real return char
            # https://stackoverflow.com/a/24276470
            fingerprint="$fingerprint $(sed -n -E 's/^label=([^'$'\r'']*)\r?/\1/p' "$autorun_inf_path")"
        fi
        
        
    elif [ "$install_type" == "steam" ]; then
        local game_exe_path=$2
        local game_exe_parent_filename
        game_exe_parent_filename="$(basename "$(dirname "$game_exe_path")")"
        fingerprint="$fingerprint $game_exe_parent_filename"
    else
        echo "Error: unknown install type '$install_type'" >&2
        exit 1
    fi
    echo "Game title fingerprint: $fingerprint" >&2
    
    
    game_slug=$(get_game_slug_from_fingerprint "$fingerprint")
    if [ -z "$game_slug" ]; then
        echo "Error: could not detect game from fingerprint" >&2  
        game_slug=$(get_game_slug_from_user)
    fi
    
    if [ -z "$game_slug" ]; then 
        echo "unknown"
    else
        echo "$game_slug"
    fi 
}

get_game_slug_from_fingerprint () {
    fingerprint=" $1 " # Add spaces to help match word boundaries
    lower_case_fingerprint=$(to_lowercase "$fingerprint")
    if [[ "$lower_case_fingerprint" == *"secrets can kill remastered"* ]] || [[ "$lower_case_fingerprint" == *"nancy drew sck"* ]]; then
        echo "secrets-can-kill-remastered"
        return
    elif [[ "$lower_case_fingerprint" == *"secrets can kill"* ]]; then
        echo "secrets-can-kill"
        return
    elif [[ "$lower_case_fingerprint" == *"stay tuned for danger"* ]] || [[ "$fingerprint" == *" STFD "* ]]; then
        echo "stay-tuned"
        return
    elif [[ "$lower_case_fingerprint" == *"message in a haunted mansion"* ]]; then
        echo "haunted-mansion"
        return
    elif [[ "$lower_case_fingerprint" == *"treasure in the royal tower"* ]]; then
        echo "royal-tower"
        return
    elif [[ "$lower_case_fingerprint" == *"the final scene"* ]]; then
        echo "final-scene"
        return
    elif [[ "$lower_case_fingerprint" == *"secret of the scarlet hand"* ]]; then
        echo "scarlet-hand"
        return
    elif [[ "$lower_case_fingerprint" == *"ghost dogs of moon lake"* ]]; then
        echo "ghost-dogs"
        return
    elif [[ "$lower_case_fingerprint" == *"the haunted carousel"* ]]; then
        echo "haunted-carousel"
        return
    elif [[ "$lower_case_fingerprint" == *"danger on deception island"* ]]; then
        echo "deception-island"
        return
    elif [[ "$lower_case_fingerprint" == *"secret of shadow ranch"* ]]; then
        echo "shadow-ranch"
        return
    elif [[ "$lower_case_fingerprint" == *"curse of blackmoor manor"* ]]; then
        echo "blackmoor-manor"
        return
    elif [[ "$lower_case_fingerprint" == *"secret of the old clock"* ]]; then
        echo "old-clock"
        return
    elif [[ "$lower_case_fingerprint" == *"last train to blue moon canyon"* ]]; then
        echo "blue-moon"
        return
    elif [[ "$lower_case_fingerprint" == *"danger by design"* ]]; then
        echo "danger-by-design"
        return
    elif [[ "$lower_case_fingerprint" == *"the creature of kapu cave"* ]]; then
        echo "kapu-cave"
        return
    elif [[ "$lower_case_fingerprint" == *"the white wolf of icicle creek"* ]]; then
        echo "white-wolf"
        return
    elif [[ "$lower_case_fingerprint" == *"legend of the crystal skull"* ]]; then
        echo "crystal-skull"
        return
    elif [[ "$lower_case_fingerprint" == *"the phantom of venice"* ]]; then
        echo "phantom-of-venice"
        return
    elif [[ "$lower_case_fingerprint" == *"the haunting of castle malloy"* ]]; then
        echo "castle-malloy"
        return
    elif [[ "$lower_case_fingerprint" == *"ransom of the seven ships"* ]]; then
        echo "seven-ships"
        return
    elif [[ "$lower_case_fingerprint" == *"warnings at waverly academy"* ]]; then
        echo "waverly-academy"
        return
    elif [[ "$lower_case_fingerprint" == *"trail of the twister"* ]]; then
        echo "trail-of-the-twister"
        return
    elif [[ "$lower_case_fingerprint" == *"shadow at the water's edge"* ]] || [[ "$lower_case_fingerprint" == *"shadow waters edge"* ]]; then
        echo "waters-edge"
        return
    elif [[ "$lower_case_fingerprint" == *"the captive curse"* ]] || [[ "$fingerprint" == *" CAP "* ]]; then
        echo "captive-curse"
        return
    elif [[ "$lower_case_fingerprint" == *"alibi in ashes"* ]]; then
        echo "alibi-in-ashes"
        return
    elif [[ "$lower_case_fingerprint" == *"tomb of the lost queen"* ]]; then
        echo "lost-queen"
        return
    elif [[ "$lower_case_fingerprint" == *"the deadly device"* ]]; then
        echo "deadly-device"
        return
    elif [[ "$lower_case_fingerprint" == *"ghost of thornton hall"* ]] || [[ "$fingerprint" == *" GTH "* ]]; then
        echo "thornton-hall"
        return
    elif [[ "$lower_case_fingerprint" == *"the silent spy"* ]] || [[ "$fingerprint" == *" SPY "* ]]; then
        echo "silent-spy"
        return
    elif [[ "$lower_case_fingerprint" == *"the shattered medallion"* ]] || [[ "$fingerprint" == *" MED "* ]]; then
        echo "shattered-medallion"
        return
    elif [[ "$lower_case_fingerprint" == *"labyrinth of lies"* ]] || [[ "$fingerprint" == *" LIE "* ]]; then
        echo "labyrinth-of-lies"
        return
    elif [[ "$lower_case_fingerprint" == *"sea of darkness"* ]] || [[ "$fingerprint" == *" SEA "* ]]; then
        echo "sea-of-darkness"
        return
    fi
}

get_game_slug_from_user() {
    game_slugs=(
        "secrets-can-kill"
        "secrets-can-kill-remastered"
        "stay-tuned"
        "haunted-mansion"
        "royal-tower"
        "final-scene"
        "scarlet-hand"
        "ghost-dogs"
        "haunted-carousel"
        "deception-island"
        "shadow-ranch"
        "blackmoor-manor"
        "old-clock"
        "blue-moon"
        "danger-by-design"
        "kapu-cave"
        "white-wolf"
        "crystal-skull"
        "phantom-of-venice"
        "castle-malloy"
        "seven-ships"
        "waverly-academy"
        "trail-of-the-twister"
        "waters-edge"
        "captive-curse"
        "alibi-in-ashes"
        "lost-queen"
        "deadly-device"
        "thornton-hall"
        "silent-spy"
        "shattered-medallion"
        "labyrinth-of-lies"
        "sea-of-darkness"
        "unknown"
    )
    game_titles=()
    for game_slug in "${game_slugs[@]}"; do
        game_title="$(get_game_info "$game_slug" "game_title")"
        if [ -z "$game_title" ]; then
            echo "Error: could not find game title for slug $game_slug" >&2
            if [ "$debug_mode" == "true" ]; then
                exit 1
            fi
        else
            game_titles+=("$game_title")
        fi
    done
    game_title=$(
        show_list_select \
            "Game could not be auto-detected. Please select the game you are installing:" \
            "" \
            "${game_titles[@]}"
    )
    for i in "${!game_titles[@]}"; do
        if [[ "${game_titles[$i]}" == "$game_title" ]]; then
            echo "${game_slugs[$i]}"
            return
        fi
    done
    echo "Game title \"$game_title\" could not be mapped to game slug" >&2
    exit 1
}

handle_int () {
    local return_value=$?
    echo Interupted. Cleaning up...
    cleanup
    exit $return_value
}

handle_error () {
    local return_value=$1
    echo "DETAILS:SHOW" >&4
    echo "" >&4
    echo "An error occurred ($return_value). Cleaning up..." >&4
    echo "Please report this error by posting in https://www.reddit.com/mod/SecondChanceHelpDesk/ (or create a GitHub issue if you have a GitHub account) and including a copy of the above log." >&4
    cleanup
    trap 'true' EXIT # Remove exit trap so that cleanup is not called again
    exit "$return_value"
}

handle_exit () {
    local return_value=$?
    echo Finished. Cleaning up...
    cleanup
    exit $return_value
}

trap 'handle_int' INT
trap 'handle_error $?' ERR
trap 'handle_exit' EXIT

main

