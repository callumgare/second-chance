#!/bin/bash
set -euo pipefail

# This script downloads and embeds ScummVM into the SecondChance app bundle
# Similar to setup-autoit.sh, it uses a cache to avoid re-downloading

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Cache directory
CACHE_DIR="${HOME}/Library/Caches/SecondChance"
SCUMMVM_CACHE="${CACHE_DIR}/scummvm"

echo "🔍 Setting up ScummVM for SecondChance..."

# ScummVM download settings
SCUMMVM_VERSION="2.8.1"
SCUMMVM_URL="https://downloads.scummvm.org/frs/scummvm/${SCUMMVM_VERSION}/scummvm-${SCUMMVM_VERSION}-macosx.dmg"
SCUMMVM_DMG="${CACHE_DIR}/scummvm-${SCUMMVM_VERSION}.dmg"
SCUMMVM_MOUNT_PATH="/tmp/scummvm-mount-$$"

WRAPPER_CONTENTS_DIR="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents"

# Destination in app bundle
SCUMMVM_RESOURCES_DEST="${WRAPPER_CONTENTS_DIR}/Resources/scummvm"

# Create cache directory if needed
mkdir -p "${CACHE_DIR}"

# Download if not cached
if [ ! -f "${SCUMMVM_DMG}" ]; then
    echo "📥 Downloading ScummVM ${SCUMMVM_VERSION}..."
    curl -fL "${SCUMMVM_URL}" -o "${SCUMMVM_DMG}.tmp"
    mv "${SCUMMVM_DMG}.tmp" "${SCUMMVM_DMG}"
    echo "✓ Downloaded ScummVM"
else
    echo "✓ Using cached ScummVM DMG"
fi

# Extract if not already extracted
if [ ! -d "${SCUMMVM_CACHE}" ]; then
    echo "📦 Extracting ScummVM from DMG..."
    
    # Remove old mount if it exists
    if [ -d "${SCUMMVM_MOUNT_PATH}" ]; then
        hdiutil detach "${SCUMMVM_MOUNT_PATH}" 2>/dev/null || true
        rm -rf "${SCUMMVM_MOUNT_PATH}"
    fi
    
    # Mount the DMG
    mkdir -p "${SCUMMVM_MOUNT_PATH}"
    hdiutil attach "${SCUMMVM_DMG}" -mountpoint "${SCUMMVM_MOUNT_PATH}" -nobrowse -quiet
    
    # Create temporary extraction directory
    SCUMMVM_TMP="${CACHE_DIR}/scummvm.tmp"
    rm -rf "${SCUMMVM_TMP}"
    mkdir -p "${SCUMMVM_TMP}/Resources" "${SCUMMVM_TMP}/Frameworks"
    
    # Copy the binary and data files we need
    SCUMMVM_APP="${SCUMMVM_MOUNT_PATH}/ScummVM.app"
    cp "${SCUMMVM_APP}/Contents/MacOS/scummvm" "${SCUMMVM_TMP}/Resources/"
    cp "${SCUMMVM_APP}/Contents/Resources/nancy.dat" "${SCUMMVM_TMP}/Resources/"
    cp "${SCUMMVM_APP}/Contents/Resources/shaders.dat" "${SCUMMVM_TMP}/Resources/"
    cp "${SCUMMVM_APP}/Contents/Resources/translations.dat" "${SCUMMVM_TMP}/Resources/"
    cp "${SCUMMVM_APP}/Contents/Resources/gui-icons.dat" "${SCUMMVM_TMP}/Resources/"
    
    # Copy frameworks (needed for Sparkle and other dependencies)
    cp -r "${SCUMMVM_APP}/Contents/Frameworks/"* "${SCUMMVM_TMP}/Frameworks/"
    
    # Unmount the DMG
    hdiutil detach "${SCUMMVM_MOUNT_PATH}" -quiet
    rm -rf "${SCUMMVM_MOUNT_PATH}"
    
    # Rename to cache location
    mv "${SCUMMVM_TMP}" "${SCUMMVM_CACHE}"
    
    echo "✓ Extracted ScummVM"
else
    echo "✓ Using cached ScummVM directory"
fi

# Copy to app bundle
echo "📋 Copying ScummVM to app bundle..."
echo "  Source: ${SCUMMVM_CACHE}"
echo "  Resources Dest: ${SCUMMVM_RESOURCES_DEST}"

# Create Resources directory if it doesn't exist
mkdir -p "$(dirname "${SCUMMVM_RESOURCES_DEST}")"

# Remove old version if it exists
if [ -d "${SCUMMVM_RESOURCES_DEST}" ]; then
    rm -rf "${SCUMMVM_RESOURCES_DEST}"
fi

# Copy ScummVM
/usr/bin/ditto --rsrc "${SCUMMVM_CACHE}/" "${SCUMMVM_RESOURCES_DEST}"
# Copy our custom scummvm.ini config file
cp "${SCRIPT_DIR}/scummvm.ini" "${SCUMMVM_RESOURCES_DEST}/"

echo "✅ ScummVM embedded successfully in ${PRODUCT_NAME}.app"
