#!/bin/bash
set -euo pipefail

# This script downloads and embeds AutoIt into the SecondChance app bundle
# It uses a cache to avoid re-downloading

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Cache directory
CACHE_DIR="${HOME}/Library/Caches/SecondChance"

echo "🔍 Setting up AutoIt for SecondChance..."

# AutoIt download settings: pinned to the tested release and checked against
# its SHA-256 (download-verified.sh). The cache names carry the version, so a
# new version is downloaded and extracted afresh.
AUTOIT_VERSION="3.3.18.0"
AUTOIT_URL="https://www.autoitscript.com/autoit3/files/archive/autoit/autoit-v${AUTOIT_VERSION}.zip"
AUTOIT_SHA256="ceb666a993a9f62621c3a0d4ee602774b2e7f543de1f08ec0380632ee3f89beb"
AUTOIT_ZIP="${CACHE_DIR}/autoit-v${AUTOIT_VERSION}.zip"
AUTOIT_CACHE="${CACHE_DIR}/autoit-${AUTOIT_VERSION}"

# Destination in app bundle
AUTOIT_DEST="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/autoit"

# shellcheck source=download-verified.sh
source "${SCRIPT_DIR}/download-verified.sh"
fetch_verified "${AUTOIT_URL}" "${AUTOIT_ZIP}" "${AUTOIT_SHA256}"

# Extract if not already extracted. Unpacked beside the cache, then renamed
# into place whole, so an interrupted unzip never leaves a half-filled cache.
if [ ! -d "${AUTOIT_CACHE}" ]; then
    echo "📦 Extracting AutoIt..."
    EXTRACT_TMP="$(mktemp -d "${CACHE_DIR}/autoit-extract.XXXXXX")"
    unzip -q "${AUTOIT_ZIP}" -d "${EXTRACT_TMP}"
    mv "${EXTRACT_TMP}/install" "${AUTOIT_CACHE}"
    rm -rf "${EXTRACT_TMP}"
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
