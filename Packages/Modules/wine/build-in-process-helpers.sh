#!/usr/bin/env bash
# Enable strict mode
set -euo pipefail
IFS=$'\n\t'

# Builds the wine module's in-process helpers into the template's Frameworks.
#
# The helpers have to run inside the Wine process that owns the game window:
# macOS only lets a process fullscreen its own NSWindow, or send its own window
# events, without the Accessibility permission. DYLD_INSERT_LIBRARIES does not
# work here -- wine-preloader reaches its entry point before dyld runs
# initializers -- so instead Wine's Mac driver gets a weak dependency on the
# dylib, added when Wine is prepared (WineBuild.prepare, MachOPatch). The
# helpers share the one dylib: native_fullscreen.m (macOS fullscreen),
# display_below_notch.m (shows Wine a notched display without the notch's
# strip, so a game in a fullscreen Space gets matching mouse positions),
# cursor_lock.m (cnc-ddraw's cursor lock), emulated_mode_scaling.m (scales a
# Direct3D game's picture up when Wine emulates the display mode it asked for),
# quit_watch.m (tells the wrapp when the game first drew and whether it was
# asked to quit, so an exit before then reads as a failure),
# cocoa_start_wait.m (lets every Wine process's driver wait for Cocoa to
# start beyond Wine's 5 s, which a busy Mac runs out),
# hidden_windows.m (keeps Big Fish's Game Manager off the screen but to sign
# in), puppet_control.m (lets the integration tests' WrappPuppeteer see and
# click the game) and virtual_pointer.m (shows Wine a pointer that moves, for
# those clicks, in a login where the Mac's can't; it wraps display_below_notch.m's
# wrappers, so it is linked after it). ScummVM wrapps load the same dylib into scummvm, for
# puppet_control.m alone. ScreenCaptureKit is weak-linked: puppet_control.m
# needs macOS 14.4 and checks for it.
# See docs/wine-in-process-helpers.md.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HELPERS_DIR="${SCRIPT_DIR}/InProcessHelpers"
FRAMEWORKS_DIR="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Frameworks"
DYLIB="${FRAMEWORKS_DIR}/in_process_helpers.dylib"

echo "🖥️  Building in-process helpers (native fullscreen, cursor lock, mode scaling, quit watch, Cocoa start wait, hidden windows, puppet control)..."
mkdir -p "${FRAMEWORKS_DIR}"
clang -dynamiclib \
    -o "${DYLIB}" \
    "${HELPERS_DIR}/native_fullscreen.m" \
    "${HELPERS_DIR}/display_below_notch.m" \
    "${HELPERS_DIR}/cursor_lock.m" \
    "${HELPERS_DIR}/emulated_mode_scaling.m" \
    "${HELPERS_DIR}/puppet_control.m" \
    "${HELPERS_DIR}/quit_watch.m" \
    "${HELPERS_DIR}/cocoa_start_wait.m" \
    "${HELPERS_DIR}/hidden_windows.m" \
    "${HELPERS_DIR}/virtual_pointer.m" \
    -framework Cocoa \
    -framework OpenGL \
    -framework ImageIO \
    -weak_framework ScreenCaptureKit \
    -arch arm64 -arch x86_64 \
    -mmacosx-version-min=11.0 \
    -fobjc-arc -O2 -Wall

# Sign explicitly. ld only auto-signs the arm64 slice ("linker-signed"), and
# Xcode's bundle signing then fails on the unsigned x86_64 slice. --force signs
# every slice.
codesign --force --sign - "${DYLIB}"
echo "✓ Built and signed in_process_helpers.dylib"
