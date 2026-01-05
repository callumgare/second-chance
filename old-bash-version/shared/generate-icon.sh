#!/usr/bin/env bash

# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

icon_source=$(realpath $1)
icon_filename=$2

icon_source_filename=$(basename "$icon_source")

temp_dir="/tmp"
temp_iconset_path="$temp_dir/second-chance-game-icon.iconset"
icon_png="$temp_dir/$icon_source_filename.png"

magick -background none "$icon_source" "$icon_png" 

if [ -e "$temp_iconset_path" ]; then
  rm -R "$temp_iconset_path"
fi
mkdir "$temp_iconset_path"

sips -z 16 16     "$icon_png" --out "$temp_iconset_path/icon_16x16.png"
sips -z 32 32     "$icon_png" --out "$temp_iconset_path/icon_16x16@2x.png"
sips -z 32 32     "$icon_png" --out "$temp_iconset_path/icon_32x32.png"
sips -z 64 64     "$icon_png" --out "$temp_iconset_path/icon_32x32@2x.png"
sips -z 128 128   "$icon_png" --out "$temp_iconset_path/icon_128x128.png"
sips -z 256 256   "$icon_png" --out "$temp_iconset_path/icon_128x128@2x.png"
sips -z 256 256   "$icon_png" --out "$temp_iconset_path/icon_256x256.png"
sips -z 512 512   "$icon_png" --out "$temp_iconset_path/icon_256x256@2x.png"
sips -z 512 512   "$icon_png" --out "$temp_iconset_path/icon_512x512.png"
cp                "$icon_png"       "$temp_iconset_path/icon_512x512@2x.png"

iconutil -c icns -o "$icon_filename" "$temp_iconset_path" 
rm -R "$temp_iconset_path"