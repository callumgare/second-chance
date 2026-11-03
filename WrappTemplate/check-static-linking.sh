#!/usr/bin/env bash
# Enable strict mode
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

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
    echo "Engines are installed into a wrapp's Contents/Frameworks beside the launcher's"
    echo "files, so the launcher keeps nothing there of its own but the in-process helpers."
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

# The same for the shared packages' modules (Packages/).
for MODULE in SecondChanceKit SecondChanceReporting GameCatalog; do
    if otool -L "${GAMEWRAPPER_BINARY}" | grep -i "${MODULE}.framework" \
        || [ -d "${BUILD_DIR}/PackageFrameworks/${MODULE}.framework" ]; then
        echo "❌ ERROR: ${MODULE} is dynamically linked!"
        echo ""
        echo "Leave its library product's type unset in its Package.swift under Packages/,"
        echo "so Xcode links it statically."
        exit 1
    fi
done
echo "✅ The shared packages are statically linked"

touch "${DERIVED_FILE_DIR}/check-static-linking-last-run"
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
