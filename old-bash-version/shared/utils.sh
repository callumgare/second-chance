#!/usr/bin/env bash
# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -Eeuo pipefail
IFS=$'\n\t'

returned_array=()

return_as_array() {
    # shellcheck disable=SC2034 # returned_array is a global variable which is read by the caller
    returned_array=("$@")
}

newline_separated_list_to_array() {
    local IFS=$'\n'
    # shellcheck disable=SC2206 # We want quotespliting in this case
    local -a array_list=( $1 )
    return_as_array "${array_list[@]}"
}

to_lowercase() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

escape_string_for_sed_regex() {
    sed -e 's/[^^]/[&]/g; s/\^/\\^/g; $!a\'$'\n''\\n' <<<"$1" | tr -d '\n';
}

get_property_from_ini () {
    # Returns the first match of a property irelevent of which section it's found in.
    # This is fine for our use cases.
    local ini_file="$1"
    local property="$2"
    # MacOS sed does not support "\r" usage in charecter classes so use a real return char
    # https://stackoverflow.com/a/24276470
    sed -n -E "s/^$(escape_string_for_sed_regex "$property")=([^"$'\r'"]*)\r?/\1/p" "$ini_file"
}

remove_prefix() {
    local string="$1"
    local prefix="$2"
    echo "${string#"$prefix"}"
}

download_file() {
    local url="$1"
    local output_file_path="$2"
    local header="${3:-}"
    if [ -f "$output_file_path" ]; then
        echo "File is already downloaded: $output_file_path"
        return
    elif [ -e "$output_file_path" ]; then
        echo "Error: Output file path exists but is not a file: $output_file_path" >&2
        return 1
    fi
    
    set -x
    if [ -n "$header" ]; then
        curl -fL -H "$header" "$url" -o "$output_file_path.tmp"
    else
        curl -fL "$url" -o "$output_file_path.tmp"
    fi
    mv "$output_file_path.tmp" "$output_file_path"
}

get_letter_from_number () {
    local number=$1
    local letter_in_hex
    letter_in_hex=$( printf %x $((number + 96)) )
    # shellcheck disable=SC2059 # We need to embed number in format string to convert from hex
    printf "\x$letter_in_hex"
}