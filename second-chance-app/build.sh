#!/usr/bin/env bash
# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

script_dir="$(dirname "$(readlink -f "$0")")"

source "$script_dir/../shared/utils.sh"
source "$script_dir/../shared/platypus.sh"

tmp_dir="$script_dir/build"
dist_dir="$script_dir/dist"

generate_icons_path="$script_dir/../shared/generate-icon.sh"
second_chance_icon="$script_dir/build/SecondChance.icns"
second_chance_icon_source="$script_dir/assets/Second Chance Icon.svg"

platypus_config_template="$script_dir/Second Chance.platypus"

built_app="$dist_dir/Second Chance.app"

winetricks_path="$tmp_dir/winetricks"

mkdir -p "$tmp_dir"
if [ -e "$dist_dir" ]; then
    rm -rf "$dist_dir"
fi
mkdir -p "$dist_dir"

main() {
    if ! [ -e "$second_chance_icon" ]; then
        "$generate_icons_path" "$second_chance_icon_source" "$second_chance_icon"
    fi
    
    download_exiftool
    download_winetricks
    download_autoit
    download_scummvm
    
    platypus_build \
        "$platypus_config_template" \
        "$built_app" \
        "$script_dir"
}

download_exiftool() {
    local exiftool_url="https://exiftool.org/Image-ExifTool-12.96.tar.gz"
    local compressed_exiftool_path="$tmp_dir/exiftool.tar.gz"
    local dist_exiftool_dirname="Image-ExifTool-12.96"
    local dist_exiftool_extracted_dir="$tmp_dir/$dist_exiftool_dirname"
    local exiftool_dir="$tmp_dir/exiftool"

    if [ -e "$exiftool_dir" ]; then
        return
    fi
    
    [ -e "$dist_exiftool_extracted_dir" ] && rm -rf "$dist_exiftool_extracted_dir"

    echo "Downloading exiftool"
    if ! [ -e "$compressed_exiftool_path" ]; then
        curl -L "$exiftool_url" -o "$compressed_exiftool_path.tmp"
        mv "$compressed_exiftool_path.tmp" "$compressed_exiftool_path"
    fi

    echo Extracting exiftool
    tar xf "$compressed_exiftool_path" -C "$tmp_dir"
    # find "$dist_exiftool_extracted_dir" \
    #     ! -path "$dist_exiftool_extracted_dir/exiftool" \
    #     ! -path "$dist_exiftool_extracted_dir/lib/File" \
    # mkdir \
    #     "$exiftool_tmp_dir" \
    #     "$exiftool_tmp_dir/lib" \
    #     "$exiftool_tmp_dir/lib/Image" \
    #     "$exiftool_tmp_dir/lib/Image/ExifTool"
    # mv "$dist_exiftool_tmp_dir/exiftool" "$exiftool_tmp_dir" 
    # mv "$dist_exiftool_tmp_dir/lib/File" "$exiftool_tmp_dir/lib" 
    # mv "$dist_exiftool_tmp_dir/lib/Image/ExifTool.pm" "$exiftool_tmp_dir/lib/Image" 
    # mv "$dist_exiftool_tmp_dir/lib/Image/ExifTool/Charset" "$exiftool_tmp_dir/lib/Image/ExifTool" 
    # mv "$dist_exiftool_tmp_dir/lib/Image/ExifTool/Charset.pm" "$exiftool_tmp_dir/lib/Image/ExifTool" 
    # mv "$dist_exiftool_tmp_dir/lib/Image/ExifTool/EXE.pm" "$exiftool_tmp_dir/lib/Image/ExifTool"
    # mv "$dist_exiftool_tmp_dir/lib/Image/ExifTool/Exif.pm" "$exiftool_tmp_dir/lib/Image/ExifTool"
    # mv "$dist_exiftool_tmp_dir/lib/Image/ExifTool/MakerNotes.pm" "$exiftool_tmp_dir/lib/Image/ExifTool"
    # mv "$dist_exiftool_tmp_dir/lib/Image/ExifTool/Shortcuts.pm" "$exiftool_tmp_dir/lib/Image/ExifTool"
    # mv "$dist_exiftool_tmp_dir/lib/Image/ExifTool/FlashPix.pm" "$exiftool_tmp_dir/lib/Image/ExifTool"
    mv "$dist_exiftool_extracted_dir" "$exiftool_dir"
    
    
}

download_winetricks() {
    winetricks_url="https://raw.githubusercontent.com/Kegworks-App/winetricks/kegworks/src/winetricks"

    echo "Downloading winetricks"
    download_file "$winetricks_url" "$winetricks_path"
    chmod +x "$winetricks_path"
}

download_autoit() {
    local autoit_url="https://www.autoitscript.com/cgi-bin/getfile.pl?autoit3/autoit-v3.zip"
    local compressed_autoit_path="$tmp_dir/autoit-v3.zip"
    local dist_autoit_dirname="install"
    local dist_autoit_extracted_dir="$tmp_dir/$dist_autoit_dirname"
    local autoit_dir="$tmp_dir/autoit"

    if ! [ -e "$autoit_dir" ]; then
        [ -e "$dist_autoit_extracted_dir" ] && rm -rf "$dist_autoit_extracted_dir"

        echo "Downloading autoit"
        download_file "$autoit_url" "$compressed_autoit_path"

        echo Extracting autoit
        unzip "$compressed_autoit_path" -d "$tmp_dir"
        mv "$dist_autoit_extracted_dir" "$autoit_dir"
    fi
}

download_scummvm() {
    local scummvm_url="https://downloads.scummvm.org/frs/scummvm/2.8.1/scummvm-2.8.1-macosx.dmg"
    local scummvm_dmg_path="$tmp_dir/scummvm.dmg"
    local scummvm_dmg_mount_path="$tmp_dir/scummvm"
    local scummvm_path="$tmp_dir/scummvm"
    
    if [ -e "$scummvm_path" ]; then
        return
    fi

    echo "Downloading ScummVM"
    local scummvm_tmp_path="$scummvm_path.tmp"
    download_file "$scummvm_url" "$scummvm_dmg_path"
        
    if [ -e "$scummvm_dmg_mount_path" ]; then
        hdiutil detach "$scummvm_dmg_mount_path"
    fi
    hdiutil mount -mountpoint "$scummvm_dmg_mount_path" "$scummvm_dmg_path"
    local scummvm_app_path="$scummvm_dmg_mount_path/ScummVM.app"

    if [ -e "$scummvm_tmp_path" ]; then
        rm -rf "$scummvm_tmp_path"
    fi
    mkdir "$scummvm_tmp_path" \
        "$scummvm_tmp_path/Frameworks" \
        "$scummvm_tmp_path/Resources"
    
    # cp -r "$scummvm_app_path/Contents/Frameworks/"* "$scummvm_tmp_path/Frameworks"
    cp -r "$scummvm_app_path/Contents/MacOS/scummvm" "$scummvm_tmp_path/Resources"
    cp -r "$scummvm_app_path/Contents/Resources/nancy.dat" "$scummvm_tmp_path/Resources"
    cp -r "$scummvm_app_path/Contents/Resources/shaders.dat" "$scummvm_tmp_path/Resources"
    cp -r "$scummvm_app_path/Contents/Resources/translations.dat" "$scummvm_tmp_path/Resources"
    cp -r "$scummvm_app_path/Contents/Resources/gui-icons.dat" "$scummvm_tmp_path/Resources"
    cp -r "$scummvm_app_path/Contents/Resources/scummremastered.zip" "$scummvm_tmp_path/Resources"

    hdiutil detach "$scummvm_dmg_mount_path"
    mv "$scummvm_tmp_path" "$scummvm_path"
}


main