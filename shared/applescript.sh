#!/usr/bin/env bash

# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -Eeuo pipefail
IFS=$'\n\t'

show_list_select() {
    local prompt_message
    prompt_message=$(escape_applescript_string "$1")
    local additional_options="$2"
    shift
    shift
    local applescript_list
    applescript_list=$(printf ', "%s"' "$@")
    
    print_open_dialog_message
    
    local result
    result=$(osascript -e "choose from list {$applescript_list} with prompt \"$prompt_message\" $additional_options")
    bring_app_to_front
    if [ "$result" != "false" ]; then
        echo "$result"
    fi
}

escape_applescript_string () {
    echo "$1" | sed -E 's/\\/\\\\/g' | sed -E 's/\\?"/\\"/g'
}

show_button_select_dialog () {
    local prompt_message
    prompt_message=$(escape_applescript_string "$1")
    local additional_options="$2"
    shift
    shift
    
    print_open_dialog_message
    
    local applescript_buttons_list
    applescript_buttons_list=$(printf ', "%s"' "$@")
    osascript -e "button returned of (display dialog \"$prompt_message\" buttons {$applescript_buttons_list} $additional_options)"
    bring_app_to_front
}

show_folder_selection_dialog () {
    local prompt_message
    prompt_message=$(escape_applescript_string "$1")
    local additional_options="$2"
    
    print_open_dialog_message
    
    osascript -e "POSIX path of (choose folder with prompt \"$prompt_message\" $additional_options)"
    bring_app_to_front
}

show_text_selection_dialog () {
    local prompt_message
    prompt_message=$(escape_applescript_string "$1")
    local default_answer
    default_answer=$(escape_applescript_string "$2")
    local additional_options="$3"
    shift
    shift
    shift
    
    print_open_dialog_message
    
    local applescript_buttons_list
    applescript_buttons_list=$(printf ', "%s"' "$@")
    osascript -e "text returned of (display dialog \"$prompt_message\" default answer \"$default_answer\" buttons {$applescript_buttons_list} $additional_options)"
    bring_app_to_front
}

show_alert () {
    local prompt_title
    prompt_title=$(escape_applescript_string "$1")
    local additional_options="${2:-}"
    
    print_open_dialog_message
    
    
    applescript_command="display alert \"$prompt_title\" $additional_options"
    
    if [ "$#" -gt 2 ]; then
        shift
        shift
        local applescript_buttons_list
        applescript_buttons_list=$(printf ', "%s"' "$@")
        applescript_command="$applescript_command buttons {$applescript_buttons_list}"
    fi
    
    osascript -e "button returned of ($applescript_command)"
    bring_app_to_front
}

print_open_dialog_message () {
    message="Waiting for user to respond to open dialog"
    if [ "${global_output_is_redirected:-}" == "true" ]; then 
        echo "$message" >&3
    else
        echo "$message"
    fi
}

# shellcheck disable=SC2120 # Argument is optional
bring_app_to_front () {
    local app_path
    app_path=$(ps -o comm= -p "$(ps -o ppid= -p $$)" | sed -E 's/(.*\.app\/).*/\1/')
    osascript -e "tell application \"$(escape_applescript_string "$app_path")\""$'\n''   activate'$'\n''end tell'
}