#!/bin/bash
set -euo pipefail

# This script downloads and embeds exiftool into the SecondChance app bundle
# Similar to download-wine.sh, it uses a cache to avoid re-downloading

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Cache directory
CACHE_DIR="${HOME}/Library/Caches/SecondChance"
EXIFTOOL_CACHE="${CACHE_DIR}/exiftool"

echo "🔍 Setting up exiftool for SecondChance..."

# Destination in app bundle
EXIFTOOL_DEST="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/exiftool"

# Create cache directory if needed
mkdir -p "${CACHE_DIR}"

# Everything below is only needed to populate ${EXIFTOOL_CACHE}. Once that
# exists the version is irrelevant, so a warm cache needs no network at all.
if [ -d "${EXIFTOOL_CACHE}" ]; then
    echo "✓ Using cached exiftool directory"
else
    # Fetch latest version from GitHub
    echo "📡 Fetching latest exiftool version from GitHub..."

    # api.github.com allows only 60 unauthenticated requests per hour per IP,
    # and CI runners share IPs — hence the HTTP 403 this used to fail on.
    # Authenticating raises that to 1000/hour for the repo; GitHub Actions
    # supplies the token via the workflow's `env:`.
    # ([@]+ guard: bash 3.2 on macOS errors on "${arr[@]}" if the array is ever empty under `set -u`)
    API_HEADERS=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
    if [ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]; then
        API_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN:-${GH_TOKEN:-}}")
    fi

    # Fetch to a variable first to avoid curl getting SIGPIPE from grep -m 1 under set -o pipefail
    TAGS_JSON=$(curl -fsSL ${API_HEADERS[@]+"${API_HEADERS[@]}"} https://api.github.com/repos/exiftool/exiftool/tags)
    EXIFTOOL_VERSION=$(printf '%s' "$TAGS_JSON" | grep -m 1 '"name":' | sed -E 's/.*"name": ?"([^"]+)".*/\1/')
    echo "✓ Latest version: ${EXIFTOOL_VERSION}"

    # Download settings - use GitHub release tarball
    EXIFTOOL_URL="https://github.com/exiftool/exiftool/archive/refs/tags/${EXIFTOOL_VERSION}.tar.gz"
    EXIFTOOL_TARBALL="${CACHE_DIR}/exiftool-${EXIFTOOL_VERSION}.tar.gz"
    EXTRACTED_DIR="${CACHE_DIR}/exiftool-${EXIFTOOL_VERSION}"

    # Download if not cached
    if [ ! -f "${EXIFTOOL_TARBALL}" ]; then
        echo "📥 Downloading exiftool ${EXIFTOOL_VERSION}..."
        curl -fL "${EXIFTOOL_URL}" -o "${EXIFTOOL_TARBALL}.tmp"
        mv "${EXIFTOOL_TARBALL}.tmp" "${EXIFTOOL_TARBALL}"
        echo "✓ Downloaded exiftool"
    else
        echo "✓ Using cached exiftool tarball"
    fi

    echo "📦 Extracting exiftool..."

    # Remove old extraction directory if it exists
    [ -d "${EXTRACTED_DIR}" ] && rm -rf "${EXTRACTED_DIR}"

    # Extract
    tar -xzf "${EXIFTOOL_TARBALL}" -C "${CACHE_DIR}"

    # Rename to cache location
    mv "${EXTRACTED_DIR}" "${EXIFTOOL_CACHE}"

    echo "✓ Extracted exiftool"
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

