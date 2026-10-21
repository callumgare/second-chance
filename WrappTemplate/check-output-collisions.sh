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
    echo "⚠️  Warning: WrappTemplate binary not found at ${GAMEWRAPPER_BINARY}, skipping static linking check"
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
    echo "⚠️  Warning: No Logging symbols found in WrappTemplate binary"
    echo "This may indicate swift-log is not linked properly"
fi

echo "✅ swift-log is statically linked"

touch "${DERIVED_FILE_DIR}/check-output-collisions-last-run"
echo "🔍 Verifying Sentry static linking (no dynamic framework)..."

# Same reason as swift-log: a wrapp's Contents/Frameworks is replaced by the
# engine's, so a dynamic Sentry.framework would be gone by launch time.
if otool -L "${GAMEWRAPPER_BINARY}" | grep -i "sentry.framework"; then
    echo "❌ ERROR: Sentry.framework is dynamically linked!"
    echo ""
    echo "Link the static 'Sentry' product, not 'Sentry-Dynamic'"
    echo "(docs/failure-reports.md)."
    exit 1
fi

# Xcode still embeds an empty Sentry.framework, only to carry Sentry's
# privacy manifest. Nothing links it, so losing it with Contents/Frameworks
# is harmless. The code is in the binary — or, in a Debug build, in the
# debug dylib beside it.
SENTRY_CODE="${GAMEWRAPPER_BINARY}"
if [ -f "${GAMEWRAPPER_BINARY}.debug.dylib" ]; then
    SENTRY_CODE="${GAMEWRAPPER_BINARY}.debug.dylib"
fi
if otool -L "${SENTRY_CODE}" | grep -i "sentry.framework"; then
    echo "❌ ERROR: Sentry.framework is dynamically linked!"
    exit 1
fi
# grep -c reads to the end: grep -q would stop early, nm would die of
# SIGPIPE, and pipefail would make that look like no match.
if [ "$(nm "${SENTRY_CODE}" | grep -c "SentrySDK")" = "0" ]; then
    echo "⚠️  Warning: No Sentry symbols found in WrappTemplate binary"
    echo "This may indicate Sentry is not linked properly"
fi

echo "✅ Sentry is statically linked"
