#!/usr/bin/env bash
# Enable strict mode
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "🔍 Checking for output file collisions..."

WINE_LIST="${SCRIPT_DIR}/Resources/wine-files"
SCUMMVM_LIST="${SCRIPT_DIR}/Resources/scummvm-files"

# Check if both files exist
if [ ! -f "${WINE_LIST}" ]; then
    echo "⚠️  Warning: ${WINE_LIST} not found, skipping collision check"
    exit 0
fi

if [ ! -f "${SCUMMVM_LIST}" ]; then
    echo "⚠️  Warning: ${SCUMMVM_LIST} not found, skipping collision check"
    exit 0
fi

# Find duplicates
DUPLICATES=$(comm -12 <(sort "${WINE_LIST}") <(sort "${SCUMMVM_LIST}"))

if [ -n "${DUPLICATES}" ]; then
    echo "❌ ERROR: Output file collisions detected!"
    echo ""
    echo "The following files are listed in both wine-files and scummvm-files:"
    echo "${DUPLICATES}"
    echo ""
    echo "Each file should only be created by one build phase."
    exit 1
fi

echo "✅ No output file collisions detected"

echo "🔍 Verifying swift-log static linking (no dynamic framework)..."

GAMEWRAPPER_BINARY="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/MacOS/${PRODUCT_NAME}"

if [ ! -f "${GAMEWRAPPER_BINARY}" ]; then
    echo "⚠️  Warning: GameWrapper binary not found at ${GAMEWRAPPER_BINARY}, skipping static linking check"
    exit 0
fi

# Check that no Logging.framework is dynamically linked
if otool -L "${GAMEWRAPPER_BINARY}" | grep -i "logging.framework"; then
    echo "❌ ERROR: Logging.framework is dynamically linked!"
    echo ""
    echo "This would cause wrapper apps to fail at launch because"
    echo "setupWineFramework deletes Contents/Frameworks wholesale."
    echo ""
    echo "Dependencies:"
    otool -L "${GAMEWRAPPER_BINARY}"
    exit 1
fi

# Check that PackageFrameworks directory doesn't contain Logging.framework
if [ -d "${BUILD_DIR}/PackageFrameworks/Logging.framework" ]; then
    echo "❌ ERROR: Logging.framework found in PackageFrameworks!"
    echo ""
    echo "This indicates dynamic linking. swift-log must be statically linked."
    exit 1
fi

# Check that the binary contains Logging symbols (confirms it's statically linked)
if ! nm "${GAMEWRAPPER_BINARY}" | grep -q "7Logging"; then
    echo "⚠️  Warning: No Logging symbols found in GameWrapper binary"
    echo "This may indicate swift-log is not linked properly"
fi

echo "✅ swift-log is statically linked"

touch "${DERIVED_FILE_DIR}/check-output-collisions-last-run"