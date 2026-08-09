#!/usr/bin/env bash
# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "🔍 Setting up Wine for SecondChance..."

# Configuration
WINE_URL="https://github.com/Kegworks-App/Engines/releases/download/v1.0/WS12WineCX24.0.7.tar.xz"
WINESKIN_URL="https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.11.tar.xz"
WINETRICKS_URL="https://raw.githubusercontent.com/Kegworks-App/winetricks/kegworks/src/winetricks"

# Download cache (persistent across builds)
DOWNLOAD_CACHE_DIR="$HOME/Library/Caches/SecondChance"
WINE_ARCHIVE="$DOWNLOAD_CACHE_DIR/wine-engine.tar.xz"
WINESKIN_ARCHIVE="$DOWNLOAD_CACHE_DIR/wineskin.tar.xz"
WINETRICKS_FILE="$DOWNLOAD_CACHE_DIR/winetricks"

WRAPPER_CONTENTS_DIR="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents"

mkdir -p "$DOWNLOAD_CACHE_DIR"

# Download archives if not cached
if [ ! -f "$WINE_ARCHIVE" ]; then
    echo "📥 Downloading Wine engine..."
    curl -L -o "$WINE_ARCHIVE.tmp" "$WINE_URL"
    mv "$WINE_ARCHIVE.tmp" "$WINE_ARCHIVE"
    echo "✓ Downloaded Wine"
else
    echo "✓ Using cached Wine archive"
fi

if [ ! -f "$WINESKIN_ARCHIVE" ]; then
    echo "📥 Downloading Wineskin frameworks..."
    curl -L -o "$WINESKIN_ARCHIVE.tmp" "$WINESKIN_URL"
    mv "$WINESKIN_ARCHIVE.tmp" "$WINESKIN_ARCHIVE"
    echo "✓ Downloaded Wineskin"
else
    echo "✓ Using cached Wineskin archive"
fi

if [ ! -f "$WINETRICKS_FILE" ]; then
    echo "📥 Downloading winetricks..."
    curl -L -o "$WINETRICKS_FILE.tmp" "$WINETRICKS_URL"
    chmod +x "$WINETRICKS_FILE.tmp"
    mv "$WINETRICKS_FILE.tmp" "$WINETRICKS_FILE"
    echo "✓ Downloaded winetricks"
else
    echo "✓ Using cached winetricks"
fi

# Create single temp directory with final structure
TEMP_DIR="${DERIVED_FILE_DIR}/wine-bundle-temp"
rm -rf "${TEMP_DIR}"
echo "📋 Creating temp directory structure..."
mkdir -p "${TEMP_DIR}/SharedSupport/wine"
mkdir -p "${TEMP_DIR}/Frameworks"
mkdir -p "${TEMP_DIR}/Resources"

# Extract Wine
echo "📦 Extracting Wine..."
tar -xf "$WINE_ARCHIVE" -C "${TEMP_DIR}/SharedSupport/wine" --strip-components=1

# Extract frameworks
echo "📦 Extracting frameworks..."
FRAMEWORKS_TEMP="${DERIVED_FILE_DIR}/wineskin-extract"
mkdir -p "${FRAMEWORKS_TEMP}"
tar -xf "$WINESKIN_ARCHIVE" -C "${FRAMEWORKS_TEMP}" --strip-components=1
ditto --rsrc "${FRAMEWORKS_TEMP}/Contents/Frameworks" "${TEMP_DIR}/Frameworks"
rm -rf "${FRAMEWORKS_TEMP}"

# Copy winetricks
echo "📋 Installing winetricks..."
ditto --rsrc "$WINETRICKS_FILE" "${TEMP_DIR}/Resources/winetricks"
chmod +x "${TEMP_DIR}/Resources/winetricks"
    
# Fix rpaths
echo "🔧 Fixing rpaths..."
for binary in "${TEMP_DIR}/SharedSupport/wine/bin"/*; do
    if [ -f "$binary" ] && [ -x "$binary" ]; then
        install_name_tool -add_rpath "@executable_path/../../../Frameworks" "$binary" 2>/dev/null || true
    fi
done

# Code sign
echo "✍️  Code signing Wine binaries and frameworks..."

# Remove *.swiftmodule directories and their contents, depth-first, without following symlinks
find "${TEMP_DIR}/Frameworks" -depth \( -path "*.swiftmodule" -o -path "*.swiftmodule/*" \) -delete

signed_count=0
already_signed_count=0
last_update=$(date +%s)

while IFS= read -r file; do
    current_time=$(date +%s)
    elapsed=$((current_time - last_update))
    
    if ! codesign -dvv "$file" &>/dev/null; then
        codesign --force --sign - "$file"
        ((signed_count++))
    else
        ((already_signed_count++))
    fi
    
    if [ $elapsed -ge 5 ]; then
        echo "📊 Progress: Signed: $signed_count, Already signed: $already_signed_count"
        last_update=$current_time
    fi
done < <(find "${TEMP_DIR}/Frameworks" -type f \( -perm +111 -o -name "*.dll" \))

echo "✅ Code signing complete: Signed: $signed_count, Already signed: $already_signed_count"

# Generate output file list from temp directory
OUTPUT_LIST="${SCRIPT_DIR}/Resources/wine-files"
echo "📝 Creating output files list..."
{
    find "${TEMP_DIR}" -type f | while read -r file; do
        echo "${file#${TEMP_DIR}/}"
    done
} > "${OUTPUT_LIST}"

# Copy from temp to wrapper
echo "📋 Copying to app bundle..."
mkdir -p "$WRAPPER_CONTENTS_DIR"
ditto --rsrc "${TEMP_DIR}/" "$WRAPPER_CONTENTS_DIR/"
rm -rf "${TEMP_DIR}"

echo "✅ Wine, frameworks, and winetricks embedded in ${PRODUCT_NAME}.app"
echo "✅ Output files list created at ${OUTPUT_LIST}"