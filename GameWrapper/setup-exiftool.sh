#!/bin/bash
set -euo pipefail

# This script downloads and embeds exiftool into the SecondChance app bundle
# Similar to download-wine.sh, it uses a cache to avoid re-downloading

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Cache directory
CACHE_DIR="${HOME}/Library/Caches/SecondChance"
EXIFTOOL_CACHE="${CACHE_DIR}/exiftool"

echo "🔍 Setting up exiftool for SecondChance..."

# Fetch latest version from GitHub
echo "📡 Fetching latest exiftool version from GitHub..."
EXIFTOOL_VERSION=$(curl -fsSL https://api.github.com/repos/exiftool/exiftool/tags | grep -m 1 '"name":' | sed -E 's/.*"name": ?"([^"]+)".*/\1/')

if [ -z "$EXIFTOOL_VERSION" ]; then
    echo "❌ Failed to fetch latest version from GitHub, using fallback version 12.96"
    EXIFTOOL_VERSION="12.96"
else
    echo "✓ Latest version: ${EXIFTOOL_VERSION}"
fi

# Download settings - use GitHub release tarball
EXIFTOOL_URL="https://github.com/exiftool/exiftool/archive/refs/tags/${EXIFTOOL_VERSION}.tar.gz"
EXIFTOOL_TARBALL="${CACHE_DIR}/exiftool-${EXIFTOOL_VERSION}.tar.gz"
EXTRACTED_DIR="${CACHE_DIR}/exiftool-${EXIFTOOL_VERSION}"

# Destination in app bundle
EXIFTOOL_DEST="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/exiftool"

# Create cache directory if needed
mkdir -p "${CACHE_DIR}"

# Download if not cached
if [ ! -f "${EXIFTOOL_TARBALL}" ]; then
    echo "📥 Downloading exiftool ${EXIFTOOL_VERSION}..."
    curl -fL "${EXIFTOOL_URL}" -o "${EXIFTOOL_TARBALL}.tmp"
    mv "${EXIFTOOL_TARBALL}.tmp" "${EXIFTOOL_TARBALL}"
    echo "✓ Downloaded exiftool"
else
    echo "✓ Using cached exiftool tarball"
fi

# Extract if not already extracted
if [ ! -d "${EXIFTOOL_CACHE}" ]; then
    echo "📦 Extracting exiftool..."
    
    # Remove old extraction directory if it exists
    [ -d "${EXTRACTED_DIR}" ] && rm -rf "${EXTRACTED_DIR}"
    
    # Extract
    tar -xzf "${EXIFTOOL_TARBALL}" -C "${CACHE_DIR}"
    
    # Rename to cache location
    mv "${EXTRACTED_DIR}" "${EXIFTOOL_CACHE}"
    
    echo "✓ Extracted exiftool"
else
    echo "✓ Using cached exiftool directory"
fi

# Copy to app bundle
echo "📋 Copying exiftool to app bundle..."
echo "  Source: ${EXIFTOOL_CACHE}"
echo "  Dest: ${EXIFTOOL_DEST}"

# Create Resources directory if it doesn't exist
mkdir -p "$(dirname "${EXIFTOOL_DEST}")"

# Remove old version if it exists
if [ -d "${EXIFTOOL_DEST}" ]; then
    rm -rf "${EXIFTOOL_DEST}"
fi

# Copy exiftool
/usr/bin/ditto --rsrc "${EXIFTOOL_CACHE}" "${EXIFTOOL_DEST}"

# Make exiftool executable
chmod +x "${EXIFTOOL_DEST}/exiftool"

echo "✅ exiftool embedded successfully in ${PRODUCT_NAME}.app"

