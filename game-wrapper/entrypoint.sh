#!/usr/bin/env bash

# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

script_dir="$(dirname "$(readlink -f "$0")")"
app_path=$(realpath "$script_dir/../..")

setting_plist_path="$app_path/Contents/Resources/AppSettings.plist"
info_plist_path="$app_path/Contents/Info.plist"

winePrefix="$app_path/Contents/SharedSupport/prefix"

game_exe_path="$winePrefix/drive_c$(plutil -extract "GameExePath" raw "$setting_plist_path")"
game_installer_dir="$winePrefix/drive_c$(plutil -extract "GameInstallerDir" raw "$setting_plist_path")"
game_engine=$(plutil -extract "GameEngine" raw "$setting_plist_path")
steam_game_id=$(plutil -extract "SteamGameId" raw "$setting_plist_path")
bundle_id_for_game_title=$(plutil -extract "CFBundleIdentifierForGameTitle" raw "$info_plist_path")

# shellcheck source=../shared/wine-lib.sh
source "$script_dir/wine-lib.sh"

# shellcheck source=../shared/applescript.sh
source "$script_dir/applescript.sh"

main() {    
    echo "Game engine: $game_engine"
    echo "Starting game..."

    # Setup application support directory for save files
    app_support_dir_path="$HOME/Library/Application Support/$bundle_id_for_game_title"

    mkdir -p "$app_support_dir_path"
    
    if [ "$game_engine" == "wine" ] || [ "$game_engine" == "wine-steam" ] || [ "$game_engine" == "wine-steam-silent" ]; then
        start_wine_server "$app_path"
        trap 'stop_wine_server "$app_path"' EXIT
        steam_messsage=""
        if [ "$game_engine" == "wine-steam" ] || [ "$game_engine" == "wine-steam-silent" ]; then
            steam_messsage=$'\n'$'\n'"Also due to the way Steam works it may take up to a 1 minute to launch the game. Sorry for the wait :("
        fi
        show_alert \
            "Save regularly to avoid losing progress" \
            "as critical message \"Crashes may occur, especially if you switch to a different app when the game is runnning.$steam_messsage\"" \
            "Understood" > /dev/null
    fi
    
    # Mount application support dir into wine enviroment
    mount_dir_into_wine_env "$app_path" "$app_support_dir_path" "a"
    game_save_path_in_wine="$winePrefix/drive_c/users/$wine_user_name/Documents"
    rm -rf "$game_save_path_in_wine"
    ln -s "$app_support_dir_path" "$game_save_path_in_wine"
    
    # Record the game engine used when first run to ensure we always use this engine
    save_file_game_engine_path="$app_support_dir_path/game-engine"
    if ! [ -e "$save_file_game_engine_path" ]; then
        echo "$game_engine" > "$save_file_game_engine_path"
    fi
    
    if [[ "$game_engine" == "scummvm" ]]; then
        # We don't use ScummVM's autorun system since it's more convenient to set game path here
        # but for more info see: https://docs.scummvm.org/en/latest/advanced_topics/autostart.html
        "$script_dir/../Resources/scummvm" -f \
            "--config=~/Library/Preferences/$bundle_id_for_game_title.ini" \
            "--initial-cfg=$script_dir/../Resources/scummvm.ini" \
            "--path=$game_installer_dir" \
            "--savepath=$app_support_dir_path" \
            --auto-detect
    
    elif [[ "$game_engine" == "wine" ]]; then
        run_with_wine_start "$app_path" "$game_exe_path"
    
    elif [[ "$game_engine" == "wine-steam" ]]; then
        # Redirecting stdout and stderr to a subshell which we use to prefix the output with 
        # a "Loading steam..." message which is shown above the progress bar.
        exec 3>&1 4>&2 
        output_prefix="Loading steam...$(printf ' %.0s' {1..300})"
        exec > >(trap "" INT TERM; sed -u "s/^/$output_prefix technical info: /")
        exec 2> >(trap "" INT TERM; sed -u "s/^/$output_prefix technical info: /" >&2)
        
        # If we start the game directly that will quit after starting a new process which loads
        # the game. When the game is quit steam remains running. To quit steam when the game is
        # quit we observe the steam logs for game stop events then manually quit steam.
        tail -n 0 -f "$winePrefix/drive_c/Program Files (x86)/Steam/logs/streaming_log.txt" > >( 
            while read -r line; do
                if [[ "${line}" == *"Removing process "* ]] && [[ "${line}" == *" for gameID "* ]]; then
                    echo "*** shutting down steam"
                    run_with_wine_start "$app_path" 'C:\Program Files (x86)\Steam\steam.exe' '-shutdown'
                    break
                fi
            done
        ) &
        
        # Show a loading bar while steam is starting. We don't know how long it will actually take
        # so we just guess.
        {
            loading_bar_time=100
            for ((i=1; i <= loading_bar_time; i++)); do
                percentage=$(echo "scale=2 ; $i / $loading_bar_time * 100" | bc)
                echo "PROGRESS:$percentage" >&4
                sleep 1
            done
        } &
        
        # May or may not launch steam depending on if game title includes DRM. If it starts steam the initial process will quit which will make the wine command end. We want to wait until all processes including the newly started steam process to end before we continue executing so we stop the wine server first so that it is implicitly started and will remain running until all wine processes have ended.
        stop_wine_server "$app_path"
        run_with_wine_start "$app_path" 'C:\Program Files (x86)\Steam\steam.exe' \
            "-cef-in-process-gpu" "-cef-disable-sandbox" "-cef-disable-gpu" '-nofriendsui' '-cef-disable-d3d11' -cef-single-process -nocrashmonitor -cef-disable-breakpad +open \
            "steam://rungameid/$steam_game_id"
            
        # Remove stdout and stderr redirect
        exec 1>&3 2>&4
    
    elif [[ "$game_engine" == "wine-steam-silent" ]]; then
        # Redirecting stdout and stderr to a subshell which we use to prefix the output with 
        # a "Loading steam..." message which is shown above the progress bar.
        exec 3>&1 4>&2 
        output_prefix="Loading steam...$(printf ' %.0s' {1..300})"
        exec > >(trap "" INT TERM; sed -u "s/^/$output_prefix technical info: /")
        exec 2> >(trap "" INT TERM; sed -u "s/^/$output_prefix technical info: /" >&2)
        
        # If we start the game directly that will quit after starting a new process which loads
        # the game. When the game is quit steam remains running. To quit steam when the game is
        # quit we observe the steam logs for game stop events then manually quit steam.
        tail -n 0 -f "$winePrefix/drive_c/Program Files (x86)/Steam/logs/streaming_log.txt" > >( 
            while read -r line; do
                if [[ "${line}" == *"Removing process "* ]] && [[ "${line}" == *" for gameID "* ]]; then
                    echo "*** shutting down steam"
                    exec 1>&3 2>&4
                    output_prefix="Quitting steam...$(printf ' %.0s' {1..300})"
                    exec > >(trap "" INT TERM; sed -u "s/^/$output_prefix technical info: /")
                    exec 2> >(trap "" INT TERM; sed -u "s/^/$output_prefix technical info: /" >&2)
                    run_with_wine_start "$app_path" 'C:\Program Files (x86)\Steam\steam.exe' '-shutdown'
                    break
                fi
            done
        ) &
        
        tail -n 0 -f "$winePrefix/drive_c/Program Files (x86)/Steam/logs/console_log.txt" > >( 
            while read -r line; do
                if [[ "${line}" == *"System startup time:"* ]]; then
                    echo "*** starting game"
                    run_with_wine_start "$app_path" "$game_exe_path"
                    break
                fi
            done
        ) &
        
        # Show a loading bar while steam is starting. We don't know how long it will actually take
        # so we just guess.
        {
            loading_bar_time=200
            for ((i=1; i <= loading_bar_time; i++)); do
                percentage=$(echo "scale=2 ; $i / $loading_bar_time * 100" | bc)
                echo "PROGRESS:$percentage" >&4
                sleep 1
            done
        } &
        
        # We can use the "steam://rungameid/{appid}" arg to start the game when launching steam
        # but for some reason if we start steam with the "-silent" param then the game doesn't load properly.
        # So instead we just start steam by it self then monitor the logs to check when it's finished starting
        # then start the game directly.
        run_with_wine_start "$app_path" 'C:\Program Files (x86)\Steam\steam.exe' \
            "-cef-in-process-gpu" "-cef-disable-sandbox" "-cef-disable-gpu" '-nofriendsui' '-silent'
            
        # Remove stdout and stderr redirect
        exec 1>&3 2>&4
    else
        echo "Unknown game engine: $game_engine" >&2
        exit 1
    fi
    echo "Quitting..."
    
    stop_wine_server "$app_path"
    echo "QUITAPP"
}

main