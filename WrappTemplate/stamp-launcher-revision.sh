#!/usr/bin/env bash
# Writes the launcher's revision into the built template's Info.plist as
# `SecondChanceLauncherRevision`: a hash of the sources the wrapp's own code
# is built from (this folder and the packages it links). Updating a wrapp
# reads it to tell whether the wrapp's launcher is this one, and so whether
# an update has anything to do (docs/wrapp-build.md#updating-a-wrapp).
#
# The sources, not the built binary: a build of the same sources needn't give
# the same bytes from one Mac or Xcode to the next. A Debug build's revision
# says so, so it never matches a release's.
set -euo pipefail

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
cd "${SRCROOT}"

REVISION="$(find WrappTemplate Packages/WrappKit/Sources Packages/SecondChanceKit/Sources Packages/GameCatalog/Sources \
    -type f ! -name '.DS_Store' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)"
if [ "${CONFIGURATION}" = "Debug" ]; then
    REVISION="debug-${REVISION}"
fi

# Only when it changes: this phase runs on every build, and rewriting the
# Info.plist each time made every incremental build sign the app again.
CURRENT="$(/usr/libexec/PlistBuddy -c "Print :SecondChanceLauncherRevision" "${PLIST}" 2>/dev/null || echo "<unset>")"
if [ "${CURRENT}" != "${REVISION}" ]; then
    /usr/libexec/PlistBuddy -c "Delete :SecondChanceLauncherRevision" "${PLIST}" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :SecondChanceLauncherRevision string ${REVISION}" "${PLIST}"
fi
echo "Launcher revision: ${REVISION}"
