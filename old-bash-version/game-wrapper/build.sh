#!/usr/bin/env bash

# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

# Change to the directory of this script so that paths are relative
script_dir="$(dirname "$(readlink -f "$0")")"
cd "$(dirname "$(readlink -f "$0")")"

source "$script_dir/../shared/wine-lib.sh"
source "$script_dir/../shared/utils.sh"
source "$script_dir/../shared/platypus.sh"

tmp_dir="build"
dist_dir="dist"
mkdir -p "$tmp_dir"
if [ -e "$dist_dir" ]; then
    rm -rf "$dist_dir"
fi
mkdir -p "$dist_dir"
tmp_dir=$(realpath "$tmp_dir")
dist_dir=$(realpath "$dist_dir")

tmp_wrapper_path="$tmp_dir/nancy-drew-wrapper.app"
zipped_tmp_wrapper_path="$tmp_dir/nancy-drew-wrapper.zip"

main() {
    generate_game_icons
    
    platypus_build "./GameWrapper.platypus" "$tmp_wrapper_path"

    add_wine_engine
    add_wine_libraries
    
    zip_app
    
    mv "$zipped_tmp_wrapper_path" "$dist_dir"
}

generate_game_icons () {
    generate_icons_path="../shared/generate-icon.sh"
    game_icon="./build/Game.icns"
    game_icon_source="./assets/Nancy Drew Game Icon.svg"
    if ! [ -e "$game_icon" ]; then
        "$generate_icons_path" "$game_icon_source" "$game_icon"
    fi
}

add_wine_engine() {
    local tmp_engine_path="$tmp_dir/wine-engine.tar.xz"
    local tmp_extracted_engine_path="$tmp_dir/wine-engine"
    local tmp_wrapper_wine_dir="$tmp_wrapper_path/Contents/SharedSupport/wine"
    # The file extention is a 7zip file but it's actually a xz file
    local wine_engine_url="https://github.com/Kegworks-App/Engines/releases/download/v1.0/WS12WineCX24.0.7.tar.xz"
    echo "Downloading wine engine"
    download_file "$wine_engine_url" "$tmp_engine_path"

    echo Extracting wine engine
    tar_extract "$tmp_engine_path" "$tmp_extracted_engine_path"
    
    mkdir -p "$(dirname "$tmp_wrapper_wine_dir")"
    cp -ac "$tmp_extracted_engine_path" "$tmp_wrapper_wine_dir"
    
    if [ ! -f "$tmp_wrapper_wine_dir/bin/wine" ]; then
        echo "Error: $tmp_wrapper_wine_dir/bin/wine does not exist."
        exit 1
    fi
}

add_wine_libraries() {
    local tmp_wineskin_wrapper_path="$tmp_dir/wineskin-wrapper.tar.xz"
    local tmp_extracted_wineskin_wrapper_path="$tmp_dir/wineskin"
    local tmp_wineskin_wrapper_framework_path="$tmp_extracted_wineskin_wrapper_path/Contents/Frameworks"
    local tmp_wrapper_wine_frameworks_dir="$tmp_wrapper_path/Contents/Frameworks"
    # The file extention is a 7zip file but it's actually a xz file
    local wineskin_wrapper_url="https://github.com/Kegworks-App/Wrapper/releases/download/v1.0/Wineskin-3.1.7_2.tar.xz"

    echo "Downloading wineskin wrapper to get wine libraries from"
    download_file "$wineskin_wrapper_url" "$tmp_wineskin_wrapper_path"

    echo Extracting wine libraries
    tar_extract "$tmp_wineskin_wrapper_path" "$tmp_extracted_wineskin_wrapper_path"

    cp -ac "$tmp_wineskin_wrapper_framework_path" "$tmp_wrapper_wine_frameworks_dir"
}

zip_app() {
    if [ -e "$zipped_tmp_wrapper_path" ]; then
        rm "$zipped_tmp_wrapper_path"
    fi
    tmp_wrapper_filename=$(basename "$tmp_wrapper_path")
    tmp_wrapper_parent_dir=$(dirname "$tmp_wrapper_path")
    pushd "$tmp_wrapper_parent_dir" && \
        zip --symlinks -r "$zipped_tmp_wrapper_path" "$tmp_wrapper_filename" && \
        popd
}

tar_extract () {
    local tar_path="$1"
    local output_path="$2"
    output_tmp_path="$output_path.tmp"
    if [ -e "$output_path" ]; then
        echo "File is already extracted: $output_path"
        return
    fi
    
    if [ -e "$output_tmp_path" ]; then
        rm -rf "$output_tmp_path"
    fi
    mkdir "$output_tmp_path"
    tar xf "$tar_path" -C "$output_tmp_path" --strip-components=1
    mv "$output_tmp_path" "$output_path"
}

main