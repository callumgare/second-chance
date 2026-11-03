#!/bin/bash
set -euo pipefail

# Downloads the official Her Interactive game patches and stages them in the
# app's download cache (Contents/Resources/downloads/<sha256>), so
# GameInstallerRunner can apply them at wrapp-build time without
# downloading anything.
#
# The patch list is the nancy-drew module's patches.json — that manifest is
# the single source of truth, shared with the Swift side (GamePatchCatalog),
# which the app reads from the module in its resources. Adding a patch means
# editing the manifest, not this script.
#
# Downloads are cached per game under ~/Library/Caches/SecondChance so repeated
# builds do not re-fetch. See docs/game-patches.md.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

MANIFEST="${SCRIPT_DIR}/../Modules/nancy-drew/patches.json"
CACHE_DIR="${HOME}/Library/Caches/SecondChance"
PATCHES_CACHE="${CACHE_DIR}/game-patches"
# Content-addressed: each download under its sha256, as later builds'
# downloads are found.
DOWNLOADS_DEST="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/downloads"

echo "🔍 Setting up game patches for SecondChance..."

if [ ! -f "${MANIFEST}" ]; then
    echo "❌ Patch manifest not found at ${MANIFEST}"
    exit 1
fi

# plutil reads JSON natively and ships with macOS, so this needs no jq/python.
read_field() {
    /usr/bin/plutil -extract "patches.$1.$2" raw -o - "${MANIFEST}" 2>/dev/null || true
}

PATCH_COUNT=$(/usr/bin/plutil -extract patches raw -o - "${MANIFEST}")

if [ -z "${PATCH_COUNT}" ] || [ "${PATCH_COUNT}" -eq 0 ]; then
    echo "ℹ️  No patches defined in ${MANIFEST}"
    exit 0
fi

echo "📋 Manifest lists ${PATCH_COUNT} patch(es)"
echo ""

# Rebuild the cache from scratch so patches dropped from the manifest do not
# linger in an incremental build.
rm -rf "${DOWNLOADS_DEST}"
mkdir -p "${DOWNLOADS_DEST}"

# shellcheck source=download-verified.sh
source "${SCRIPT_DIR}/download-verified.sh"

downloaded=0
cached=0
failed=0

index=0
while [ "${index}" -lt "${PATCH_COUNT}" ]; do
    game=$(read_field "${index}" game)
    archive=$(read_field "${index}" archive)
    url=$(read_field "${index}" url)
    patch_id=$(read_field "${index}" id)
    sha256=$(read_field "${index}" sha256)
    index=$((index + 1))

    if [ -z "${game}" ] || [ -z "${archive}" ] || [ -z "${url}" ] || [ -z "${sha256}" ]; then
        echo "⚠️  Skipping malformed manifest entry at index $((index - 1))"
        failed=$((failed + 1))
        continue
    fi

    game_cache_dir="${PATCHES_CACHE}/${game}"
    cache_file="${game_cache_dir}/${archive}"
    mkdir -p "${game_cache_dir}"

    echo "📦 ${game} / ${patch_id} (${archive})"

    was_cached=false
    if [ -f "${cache_file}" ]; then was_cached=true; fi
    if fetch_verified "${url}" "${cache_file}" "${sha256}"; then
        if ${was_cached}; then
            cached=$((cached + 1))
        else
            downloaded=$((downloaded + 1))
        fi
    else
        echo "   ❌ The wrapp will be built without this patch"
        failed=$((failed + 1))
        continue
    fi

    /usr/bin/ditto --rsrc "${cache_file}" "${DOWNLOADS_DEST}/${sha256}"
done

echo ""
echo "✅ Game patches ready — ${downloaded} downloaded, ${cached} cached, ${failed} failed"

# A failed patch download doesn't break a Debug build: the wrapp still works,
# it just ships without that fix, and GameInstallerRunner tolerates the gap.
# A Release must ship every patch, so there it fails the build.
if [ "${failed}" -gt 0 ] && [ "${CONFIGURATION:-}" = "Release" ]; then
    echo "❌ ${failed} patch(es) are missing, and a Release must ship them all"
    exit 1
fi
exit 0
