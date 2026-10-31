#!/bin/bash
set -euo pipefail

# This script downloads and embeds AutoIt into the SecondChance app bundle
# It uses a cache to avoid re-downloading

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Cache directory
CACHE_DIR="${HOME}/Library/Caches/SecondChance"
AUTOIT_CACHE="${CACHE_DIR}/autoit"

echo "🔍 Setting up AutoIt for SecondChance..."

# AutoIt download settings
AUTOIT_URL="https://www.autoitscript.com/cgi-bin/getfile.pl?autoit3/autoit-v3.zip"
AUTOIT_ZIP="${CACHE_DIR}/autoit-v3.zip"
EXTRACTED_DIR="${CACHE_DIR}/install"

# Destination in app bundle
AUTOIT_DEST="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/autoit"

# Create cache directory if needed
mkdir -p "${CACHE_DIR}"

# Download if not cached
if [ ! -f "${AUTOIT_ZIP}" ]; then
    echo "📥 Downloading AutoIt..."
    curl -fL "${AUTOIT_URL}" -o "${AUTOIT_ZIP}.tmp"
    mv "${AUTOIT_ZIP}.tmp" "${AUTOIT_ZIP}"
    echo "✓ Downloaded AutoIt"
else
    echo "✓ Using cached AutoIt zip"
fi

# Extract if not already extracted
if [ ! -d "${AUTOIT_CACHE}" ]; then
    echo "📦 Extracting AutoIt..."
    
    # Remove old extraction directory if it exists
    [ -d "${EXTRACTED_DIR}" ] && rm -rf "${EXTRACTED_DIR}"
    
    # Extract
    unzip -q "${AUTOIT_ZIP}" -d "${CACHE_DIR}"
    
    # Rename to cache location
    mv "${EXTRACTED_DIR}" "${AUTOIT_CACHE}"
    
    echo "✓ Extracted AutoIt"
else
    echo "✓ Using cached AutoIt directory"
fi

# Copy to app bundle
echo "📋 Copying AutoIt to app bundle..."
echo "  Source: ${AUTOIT_CACHE}"
echo "  Dest: ${AUTOIT_DEST}"

# Create Resources directory if it doesn't exist
mkdir -p "$(dirname "${AUTOIT_DEST}")"

# Remove old version if it exists
if [ -d "${AUTOIT_DEST}" ]; then
    rm -rf "${AUTOIT_DEST}"
fi

# Copy AutoIt
/usr/bin/ditto --rsrc "${AUTOIT_CACHE}" "${AUTOIT_DEST}"

echo "✅ AutoIt embedded successfully in ${PRODUCT_NAME}.app"
