#!/usr/bin/env bash
# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -Eeuo pipefail
IFS=$'\n\t'

wine_lib_script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

wineserver_was_manually_started=false

# shellcheck source=./applescript.sh
source "$wine_lib_script_dir/applescript.sh"

run_with_wine() (
    # Use "(" instead of "{" for function body to run in subshell
    local app_path="$1"
    shift
    local exe_path="$1"
    shift
    
    local wine_dir="$app_path/Contents/SharedSupport/wine"
    local wine_bin_dir="$wine_dir/bin"
    local wineserver_path="$wine_bin_dir/wineserver"
    local wine64_path="$wine_bin_dir/wine64"
    
    # Kill any existing wineserver processes
    if [ "$wineserver_was_manually_started" != "true" ]; then
        prompt_for_wine_kill_if_running "$app_path"
    fi
    
    # Set the working directory to the directory containing the exe
    local exe_unix_path
    exe_unix_path=$(run_with_wine_env_vars "$app_path" "$wine64_path" winepath --unix "$exe_path")
    local exe_parent_dir
    exe_parent_dir=$(dirname "$exe_unix_path")
    echo "Working dir: $exe_parent_dir"
    cd "$exe_parent_dir"
    
    # Run the exe
    local exitCode=0
    set -o xtrace
    run_with_wine_env_vars "$app_path" "$wine64_path" "$exe_path" "$@" || exitCode=$?
    set +o xtrace
    if [ $exitCode -ne 0 ]; then
        echo "Wine process returned with non-zero exit code: $exitCode" >&2
    fi

    # Wait for wineserver to exit if started automatically
    if [ "$wineserver_was_manually_started" != "true" ]; then
        time run_with_wine_env_vars "$app_path" "$wineserver_path" --wait
        echo "Time taken waiting for wineserver to exit"
    fi

    if [ $exitCode -ne 0 ]; then
        exit $exitCode
    fi
)

run_with_wine_env_vars() (
    # Use "(" instead of "{" for function body to run in subshell

    local app_path="$1"
    shift
    
    local wine_dir="$app_path/Contents/SharedSupport/wine"
    local wine_bin_dir="$wine_dir/bin"
    local wine_prefix_dir="$app_path/Contents/SharedSupport/prefix"
    local wine_frameworks_dir="$app_path/Contents/Frameworks"
    
    local dyld_fallback_library_dir
    dyld_fallback_library_dir=$( printf %s \
        "$wine_frameworks_dir/moltenvkcx:" \
        "$wine_dir/lib:" \
        "$wine_dir/lib/external:" \
        "$wine_dir/lib64:" \
        "$wine_frameworks_dir/d3dmetal/external:" \
        "$wine_frameworks_dir:" \
        "/opt/wine/lib:" \
        "$wine_frameworks_dir/GStreamer.framework/Libraries:" \
        "/usr/lib:" \
        "/usr/libexec:" \
        "/usr/lib/system:" \
        "/opt/X11/lib"
    )
    
    local env_vars
    env_vars=(
        WINEPREFIX="$wine_prefix_dir"
        # Used by winetricks
        WINE="$wine_dir/bin/wine64"
        # Use "wine" as the name for the home dir in the wine fs rather than the host user's actual username
        USER="wine"
        WINEDEBUG="-all"
        PATH="$wine_bin_dir:$PATH:/opt/local/bin:/opt/local/sbin"
        DYLD_FALLBACK_LIBRARY_PATH="$dyld_fallback_library_dir"\
        GST_PLUGIN_PATH=
        # Used by winetricks to get around SIP stripping DYLD_FALLBACK_LIBRARY_PATH when calling system programs including bash which is used to run winetricks
        WINETRICKS_FALLBACK_LIBRARY_PATH="$dyld_fallback_library_dir"
        # Disable wine dialog that shows when creating a new wine prefix
        WINEBOOT_HIDE_DIALOG=1
        CX_ROOT="$wine_dir"
        GST_PLUGIN_PATH="$wine_frameworks_dir/GStreamer.framework/Libraries/gstreamer-1.0"
        MVK_CONFIG_RESUME_LOST_DEVICE=1
        MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE=1
        WINEESYNC="${WINEESYNC:-1}"
        WINEMSYNC="${WINEMSYNC:-1}"
        MTL_HUD_ENABLED=0
        MVK_CONFIG_FAST_MATH_ENABLED=0
        DOTNET_EnableWriteXorExecute=0
    )
    
    exec env "${env_vars[@]}" "$@"
)

to_windows_path() {
    echo "C:\\$(sed -n -E 's/.*\/prefix\/drive_c\/(.*)/\1/p' <<<"$1" | tr '/' '\\')"
}

create_wine_prefix() {
    local app_path="$1"
    shift
    run_with_wine "$app_path" wineboot -u
    # Wait for wineserver (which was started by wineboot) to exit to make sure registory is fully written
    # https://github.com/The-Wineskin-Project/wineskin-source/blob/4689441c1f63facdd1513c14a32659c231cd9656/WineskinLauncher/Classes/Controller/WineskinLauncherAppDelegate.m#L1064
    wait_for_wine_to_exit "$app_path"
}

wait_for_wine_to_exit() {
    local app_path="$1"
    run_with_wine_env_vars "$app_path" "$app_path/Contents/SharedSupport/wine/bin/wineserver" -w 
}

start_wine_server() {
    # To avoid the cost of repeatedly starting and stopping the wineserver process when multiple wine processes
    # are run in quick succession, by default wineserver stays running a few second after the last wine process
    # has exited in case a new wine process is started soon after. If we know how many wine processes we are
    # going to run we can avoid the cost by manually starting wineserver and telling it not to exit automatically.
    # Then when we've run the last process we want to run we can immediately stop wineserver ourselves.
    local app_path="$1"
    
    prompt_for_wine_kill_if_running "$app_path"
    wineserver_was_manually_started=true
    run_with_wine_env_vars "$app_path" "$app_path/Contents/SharedSupport/wine/bin/wineserver" -p
}

stop_wine_server() {
    local app_path="$1"
    local wineserver_path="$app_path/Contents/SharedSupport/wine/bin/wineserver"
    if wine_is_running "$app_path"; then
        run_with_wine_env_vars "$app_path" "$wineserver_path" -kSIGINT
        run_with_wine_env_vars "$app_path" "$wineserver_path" -w
    fi
    wineserver_was_manually_started=false
}

wine_is_running() {
    local app_path="$1"
    local wineserver_path="$app_path/Contents/SharedSupport/wine/bin/wineserver"
    run_with_wine_env_vars "$app_path" "$wineserver_path" -k0
}

prompt_for_wine_kill_if_running() {
    local app_path="$1"
    local wineserver_path="$app_path/Contents/SharedSupport/wine/bin/wineserver"

    if wine_is_running "$app_path"; then
        show_button_select_dialog \
            "To continue the wine system must be restarted. Make sure you don't have any unsaved Nancy Drew games open at the moment otherwise your progress will be lost." \
            'cancel button "Cancel"' \
            "Restart Wine" \
            "Cancel"
        run_with_wine_env_vars "$app_path" "$wineserver_path" -kSIGINT
        run_with_wine_env_vars "$app_path" "$wineserver_path" --wait
    fi
}

mount_dir_into_wine_env () {
    local app_path=$1
    local dir_to_mount=$2
    local drive_letter=$3
    local drive_type=${4:-}

    local drive_path="$app_path/Contents/SharedSupport/prefix/dosdevices/$drive_letter:"

    if [ -e "$drive_path" ]; then
        rm "$drive_path"*
    fi
    ln -s "$dir_to_mount" "$drive_path"
    
    if [ -n "$drive_type" ]; then
        run_with_wine "$app_path" reg add "HKEY_LOCAL_MACHINE\Software\Wine\Drives" /v "$drive_letter:" /t REG_SZ /d "$drive_type" /f
    fi
}