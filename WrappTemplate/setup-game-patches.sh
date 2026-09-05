#!/bin/bash
set -euo pipefail

# Downloads the official Her Interactive game patches and stages them in the
# app bundle so GameInstallerRunner can apply them at wrapp-build time.
#
# The patch list lives in game-patches.json next to this script — that manifest
# is the single source of truth, shared with the Swift side (GamePatchCatalog).
# Adding a patch means editing the manifest, not this script.
#
# Downloads are cached per game under ~/Library/Caches/SecondChance so repeated
# builds do not re-fetch. See docs/game-patches.md.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

MANIFEST="${SCRIPT_DIR}/game-patches.json"
CACHE_DIR="${HOME}/Library/Caches/SecondChance"
PATCHES_CACHE="${CACHE_DIR}/game-patches"
PATCHES_DEST="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/game-patches"

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

# Rebuild the bundle directory from scratch so patches dropped from the
# manifest do not linger in an incremental build.
rm -rf "${PATCHES_DEST}"
mkdir -p "${PATCHES_DEST}"

downloaded=0
cached=0
failed=0

index=0
while [ "${index}" -lt "${PATCH_COUNT}" ]; do
    game=$(read_field "${index}" game)
    archive=$(read_field "${index}" archive)
    url=$(read_field "${index}" url)
    patch_id=$(read_field "${index}" id)
    index=$((index + 1))

    if [ -z "${game}" ] || [ -z "${archive}" ] || [ -z "${url}" ]; then
        echo "⚠️  Skipping malformed manifest entry at index $((index - 1))"
        failed=$((failed + 1))
        continue
    fi

    game_cache_dir="${PATCHES_CACHE}/${game}"
    cache_file="${game_cache_dir}/${archive}"
    mkdir -p "${game_cache_dir}"

    echo "📦 ${game} / ${patch_id} (${archive})"

    if [ -f "${cache_file}" ]; then
        echo "   ✓ Using cached download"
        cached=$((cached + 1))
    else
        echo "   ↓ Downloading ${url}"
        if curl -fsSL --retry 2 "${url}" -o "${cache_file}.tmp"; then
            mv "${cache_file}.tmp" "${cache_file}"
            echo "   ✓ Downloaded"
            downloaded=$((downloaded + 1))
        else
            echo "   ❌ Download failed — the wrapp will be built without this patch"
            rm -f "${cache_file}.tmp"
            failed=$((failed + 1))
            continue
        fi
    fi

    bundle_game_dir="${PATCHES_DEST}/${game}"
    mkdir -p "${bundle_game_dir}"
    /usr/bin/ditto --rsrc "${cache_file}" "${bundle_game_dir}/${archive}"
done

# The app reads the manifest from the bundle to decide which patches apply to
# the game and edition being built, so it ships alongside the archives.
/usr/bin/ditto --rsrc "${MANIFEST}" "${PATCHES_DEST}/manifest.json"

echo ""
echo "✅ Game patches ready — ${downloaded} downloaded, ${cached} cached, ${failed} failed"

# A failed patch download must not break the build: the wrapp still works, it
# just ships without that fix, and GameInstallerRunner tolerates the gap.
exit 0
