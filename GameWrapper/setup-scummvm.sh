#!/usr/bin/env bash
# Enable strict mode
set -euo pipefail
IFS=$'\n\t'

# This script downloads and embeds ScummVM into the SecondChance app bundle
# Similar to setup-wine.sh, it uses a cache to avoid re-downloading

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "🔍 Setting up ScummVM for SecondChance..."

# ScummVM download settings
SCUMMVM_VERSION="2026.3.0"
SCUMMVM_URL="https://downloads.scummvm.org/frs/scummvm/${SCUMMVM_VERSION}/scummvm-${SCUMMVM_VERSION}-macosx.dmg"

# Download cache (persistent across builds)
DOWNLOAD_CACHE_DIR="$HOME/Library/Caches/SecondChance"
SCUMMVM_DMG="${DOWNLOAD_CACHE_DIR}/scummvm-${SCUMMVM_VERSION}.dmg"
SCUMMVM_MOUNT_PATH="/tmp/scummvm-mount-$$"

WRAPPER_CONTENTS_DIR="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents"

# Create download cache directory if needed
mkdir -p "${DOWNLOAD_CACHE_DIR}"

# Download if not cached
if [ ! -f "${SCUMMVM_DMG}" ]; then
    echo "📥 Downloading ScummVM ${SCUMMVM_VERSION}..."
    curl -fL "${SCUMMVM_URL}" -o "${SCUMMVM_DMG}.tmp"
    mv "${SCUMMVM_DMG}.tmp" "${SCUMMVM_DMG}"
    echo "✓ Downloaded ScummVM"
else
    echo "✓ Using cached ScummVM DMG"
fi

# Remove old mount if it exists
if [ -d "${SCUMMVM_MOUNT_PATH}" ]; then
    hdiutil detach "${SCUMMVM_MOUNT_PATH}" 2>/dev/null || true
    rm -rf "${SCUMMVM_MOUNT_PATH}"
fi

# Mount the DMG
mkdir -p "${SCUMMVM_MOUNT_PATH}"
hdiutil attach "${SCUMMVM_DMG}" -mountpoint "${SCUMMVM_MOUNT_PATH}" -nobrowse -quiet

# Create single temp directory with final structure
TEMP_DIR="${DERIVED_FILE_DIR}/scummvm-bundle-temp"
rm -rf "${TEMP_DIR}"
echo "📋 Creating temp directory structure..."
mkdir -p "${TEMP_DIR}/MacOS" "${TEMP_DIR}/Resources" "${TEMP_DIR}/Frameworks"
    
# Copy the binary and data files we need to temp
echo "📦 Extracting ScummVM files..."
SCUMMVM_APP="${SCUMMVM_MOUNT_PATH}/ScummVM.app"

ditto --rsrc "${SCUMMVM_APP}/Contents/MacOS/scummvm" "${TEMP_DIR}/MacOS/scummvm"
ditto --rsrc "${SCUMMVM_APP}/Contents/Resources/nancy.dat" "${TEMP_DIR}/Resources/nancy.dat"
ditto --rsrc "${SCUMMVM_APP}/Contents/Resources/shaders.dat" "${TEMP_DIR}/Resources/shaders.dat"
ditto --rsrc "${SCUMMVM_APP}/Contents/Resources/translations.dat" "${TEMP_DIR}/Resources/translations.dat"
ditto --rsrc "${SCUMMVM_APP}/Contents/Resources/gui-icons.dat" "${TEMP_DIR}/Resources/gui-icons.dat"

# Copy frameworks (needed for Sparkle and other dependencies)
echo "📦 Extracting frameworks..."
ditto --rsrc "${SCUMMVM_APP}/Contents/Frameworks/" "${TEMP_DIR}/Frameworks/"

# Unmount the DMG
hdiutil detach "${SCUMMVM_MOUNT_PATH}" -quiet
rm -rf "${SCUMMVM_MOUNT_PATH}"

# Copy our custom scummvm.ini config file
ditto --rsrc "${SCRIPT_DIR}/scummvm.ini" "${TEMP_DIR}/Resources/scummvm.ini"

# Code sign the ScummVM executable
echo "✍️  Code signing ScummVM executable..."
codesign --force --sign - "${TEMP_DIR}/MacOS/scummvm"
echo "✅ ScummVM executable signed"

# Generate output file list from temp directory
OUTPUT_LIST="${SCRIPT_DIR}/Resources/scummvm-files"
echo "📝 Creating output files list..."
{
    find "${TEMP_DIR}" -type f | while read -r file; do
        echo "${file#${TEMP_DIR}/}"
    done
} > "${OUTPUT_LIST}"

# Copy from temp to wrapper
echo "📋 Copying to app bundle..."
mkdir -p "${WRAPPER_CONTENTS_DIR}"
ditto --rsrc "${TEMP_DIR}/" "${WRAPPER_CONTENTS_DIR}/"
rm -rf "${TEMP_DIR}"

echo "✅ ScummVM embedded successfully in ${PRODUCT_NAME}.app"
echo "✅ Output files list created at ${OUTPUT_LIST}"