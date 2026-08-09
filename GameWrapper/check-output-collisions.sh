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

touch "${DERIVED_FILE_DIR}/check-output-collisions-last-run"