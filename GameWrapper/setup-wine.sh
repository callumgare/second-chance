#!/usr/bin/env bash
# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

# Configuration
WINE_URL="https://github.com/Kegworks-App/Engines/releases/download/v1.0/WS12WineCX24.0.7.tar.xz"
WINESKIN_URL="https://github.com/Kegworks-App/Wrapper/releases/download/v1.0/Wineskin-3.1.7_2.tar.xz"
CACHE_DIR="$HOME/Library/Caches/SecondChance"
WINE_CACHE="$CACHE_DIR/wine-engine"
FRAMEWORKS_CACHE="$CACHE_DIR/wineskin-frameworks"

mkdir -p "$CACHE_DIR"

# Download and extract Wine if not cached
if [ ! -d "$WINE_CACHE" ]; then
    echo "Downloading Wine engine..."
    WINE_ARCHIVE="$CACHE_DIR/wine-engine.tar.xz"
    curl -L -o "$WINE_ARCHIVE" "$WINE_URL"
    
    echo "Extracting Wine..."
    mkdir -p "$WINE_CACHE"
    tar -xf "$WINE_ARCHIVE" -C "$WINE_CACHE" --strip-components=1
    rm "$WINE_ARCHIVE"
    echo "✅ Wine cached"
else
    echo "Using cached Wine"
fi

# Download and extract Wineskin frameworks if not cached
if [ ! -d "$FRAMEWORKS_CACHE" ]; then
    echo "Downloading Wineskin frameworks..."
    WINESKIN_ARCHIVE="$CACHE_DIR/wineskin.tar.xz"
    curl -L -o "$WINESKIN_ARCHIVE" "$WINESKIN_URL"
    
    echo "Extracting frameworks..."
    TEMP_DIR="$CACHE_DIR/wineskin-temp"
    mkdir -p "$TEMP_DIR"
    tar -xf "$WINESKIN_ARCHIVE" -C "$TEMP_DIR" --strip-components=1
    mv "$TEMP_DIR/Contents/Frameworks" "$FRAMEWORKS_CACHE"
    rm -rf "$TEMP_DIR" "$WINESKIN_ARCHIVE"
    echo "✅ Frameworks cached"
else
    echo "Using cached frameworks"
fi

echo "Copying Wine to GameWrapper-Wine.app..."
GAMEWRAPPER_APP="${BUILT_PRODUCTS_DIR}/GameWrapper.app"
WINE_DEST="${GAMEWRAPPER_APP}/Contents/SharedSupport/wine"
/usr/bin/ditto --rsrc "$WINE_CACHE" "$WINE_DEST"

echo "Copying frameworks to GameWrapper.app..."
FRAMEWORKS_DEST="${GAMEWRAPPER_APP}/Contents/Frameworks"
/usr/bin/ditto --rsrc "$FRAMEWORKS_CACHE/." "$FRAMEWORKS_DEST/"

echo "Fixing rpaths..."
for binary in "$WINE_DEST/bin"/*; do
    if [ -f "$binary" ] && [ -x "$binary" ]; then
        install_name_tool -add_rpath "@executable_path/../../../Frameworks" "$binary" 2>/dev/null || true
    fi
done

echo "Code signing Wine binaries and frameworks..."
# Sign all executable files and dylibs
find "$WINE_DEST" -type f \( -perm +111 -o -name "*.dylib" -o -name "*.so" \) -exec codesign --force --sign - {} \; 2>/dev/null || true
find "$FRAMEWORKS_DEST" -type f \( -perm +111 -o -name "*.dylib" -o -name "*.so" \) -exec codesign --force --sign - {} \; 2>/dev/null || true

echo "✅ Wine and frameworks embedded in GameWrapper.app"
