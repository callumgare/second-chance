#!/usr/bin/env bash
# Enable strict mode
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "🔍 Setting up Wine for SecondChance..."

# Configuration. Each download is pinned to the file it was tested with:
# fetch_verified (download-verified.sh) checks its SHA-256 before it is cached
# or used. Changing a URL means changing its hash too.
WINE_URL="https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_8.tar.xz"
WINE_SHA256="2a6bcf2a3bf13cddf825599b6bc1e3659cbf71e1282c6d77141a92f6ac8d4c68"
WINESKIN_URL="https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.11.tar.xz"
WINESKIN_SHA256="9fa15479e7ff6abd99c1d07be285fb95f41fc6991586502427152b1f7d6ccb8a"
# winetricks isn't fetched here: only Second Chance runs it (when it makes a
# prefix), from the copy in SecondChance/Resources, so a wrapp has no use for one.

# Download cache (persistent across builds). Named after each URL's own
# versioned file name, so changing a URL downloads the new file rather than
# reusing whichever was cached first.
DOWNLOAD_CACHE_DIR="$HOME/Library/Caches/SecondChance"
WINE_ARCHIVE="$DOWNLOAD_CACHE_DIR/$(basename "$WINE_URL")"
WINESKIN_ARCHIVE="$DOWNLOAD_CACHE_DIR/wineskin-$(basename "$WINESKIN_URL")"

WRAPPER_CONTENTS_DIR="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents"

# shellcheck source=download-verified.sh
source "${SCRIPT_DIR}/download-verified.sh"
fetch_verified "$WINE_URL" "$WINE_ARCHIVE" "$WINE_SHA256"
fetch_verified "$WINESKIN_URL" "$WINESKIN_ARCHIVE" "$WINESKIN_SHA256"

# Create single temp directory with final structure
TEMP_DIR="${DERIVED_FILE_DIR}/wine-bundle-temp"
rm -rf "${TEMP_DIR}"
echo "📋 Creating temp directory structure..."
mkdir -p "${TEMP_DIR}/SharedSupport/wine"
mkdir -p "${TEMP_DIR}/Frameworks"

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

# Build the in-process helpers and hook them into Wine's Mac driver.
#
# The helpers have to run inside the Wine process that owns the game window:
# macOS only lets a process fullscreen its own NSWindow, or send its own window
# events, without the Accessibility permission. DYLD_INSERT_LIBRARIES does not
# work here -- wine-preloader reaches its entry point before dyld runs
# initializers -- so instead the driver gets a weak dependency on the dylib.
# The helpers share the one dylib: native_fullscreen.m (macOS fullscreen),
# display_below_notch.m (shows Wine a notched display without the notch's
# strip, so a game in a fullscreen Space gets matching mouse positions),
# cursor_lock.m (cnc-ddraw's cursor lock), emulated_mode_scaling.m (scales a
# Direct3D game's picture up when Wine emulates the display mode it asked for),
# quit_watch.m (tells the wrapp when the game first drew and whether it was
# asked to quit, so an exit before then reads as a failure),
# cocoa_start_wait.m (lets every Wine process's driver wait for Cocoa to
# start beyond Wine's 5 s, which a busy Mac runs out) and
# puppet_control.m (lets the integration tests' WrappPuppeteer see and click
# the game). ScummVM wrapps load the same dylib into scummvm, for
# puppet_control.m alone. ScreenCaptureKit is weak-linked: puppet_control.m
# needs macOS 14.4 and checks for it.
# See docs/wine-in-process-helpers.md.
echo "🖥️  Building in-process helpers (native fullscreen, cursor lock, mode scaling, quit watch, Cocoa start wait, puppet control)..."
HELPERS_DIR="${SCRIPT_DIR}/InProcessHelpers"
clang -dynamiclib \
    -o "${TEMP_DIR}/Frameworks/in_process_helpers.dylib" \
    "${HELPERS_DIR}/native_fullscreen.m" \
    "${HELPERS_DIR}/display_below_notch.m" \
    "${HELPERS_DIR}/cursor_lock.m" \
    "${HELPERS_DIR}/emulated_mode_scaling.m" \
    "${HELPERS_DIR}/puppet_control.m" \
    "${HELPERS_DIR}/quit_watch.m" \
    "${HELPERS_DIR}/cocoa_start_wait.m" \
    -framework Cocoa \
    -framework OpenGL \
    -framework ImageIO \
    -weak_framework ScreenCaptureKit \
    -arch arm64 -arch x86_64 \
    -mmacosx-version-min=11.0 \
    -fobjc-arc -O2 -Wall

# Sign explicitly rather than leaving it to the generic signing loop below. ld
# only auto-signs the arm64 slice ("linker-signed"), and a bare `codesign -dvv`
# reports on the native slice alone -- so the loop sees "already signed", skips
# the file, and Xcode's bundle signing then fails on the unsigned x86_64 slice.
# --force signs every slice.
codesign --force --sign - "${TEMP_DIR}/Frameworks/in_process_helpers.dylib"
echo "✓ Built and signed in_process_helpers.dylib"

echo "🔧 Patching winemac.so to load the in-process helpers..."
"${HELPERS_DIR}/patch-winemac.swift" \
    "${TEMP_DIR}/SharedSupport/wine/lib/wine/x86_64-unix/winemac.so"

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

# Generate output file list from temp directory: what a ScummVM wrapp removes.
# Not the in-process helpers' dylib, which ScummVM wrapps load into scummvm for
# puppet control (GameLauncher).
OUTPUT_LIST="${SCRIPT_DIR}/Resources/wine-files"
echo "📝 Creating output files list..."
{
    find "${TEMP_DIR}" -type f | while read -r file; do
        echo "${file#${TEMP_DIR}/}"
    done
} | grep -v -x "Frameworks/in_process_helpers.dylib" > "${OUTPUT_LIST}"

# Copy from temp to wrapper
echo "📋 Copying to app bundle..."
mkdir -p "$WRAPPER_CONTENTS_DIR"
ditto --rsrc "${TEMP_DIR}/" "$WRAPPER_CONTENTS_DIR/"
rm -rf "${TEMP_DIR}"
# The Resources build phase has already copied Resources/ into the bundle,
# before this script regenerated the list, so copy the fresh list in too.
mkdir -p "$WRAPPER_CONTENTS_DIR/Resources"
cp "${OUTPUT_LIST}" "$WRAPPER_CONTENTS_DIR/Resources/"

echo "✅ Wine and frameworks embedded in ${PRODUCT_NAME}.app"
echo "✅ Output files list created at ${OUTPUT_LIST}"

# Stamp named to match the input declared on the "Check for collisions" phase, so
# collision checking re-runs whenever Wine bundling re-runs.
touch "${DERIVED_FILE_DIR}/wine-setup-last-run"