#!/usr/bin/env bash
# Writes SENTRY_DSN from the repo's .env into the built app's Info.plist as
# `SentryDSN`, where FailureReporter reads it. No .env, or no SENTRY_DSN in
# it, writes an empty value and the build sends no failure reports — which is
# what a fork or a contributor's build should do (docs/failure-reports.md).
#
# A script rather than an .xcconfig: xcconfig reads the `//` in a DSN as the
# start of a comment, and WrappTemplate's Info.plist is generated, which
# takes no custom keys.
set -euo pipefail

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
ENV_FILE="${SRCROOT}/.env"

DSN=""
if [ -f "${ENV_FILE}" ]; then
    # The last SENTRY_DSN= line wins, as in a shell; quotes are optional.
    DSN="$(sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?SENTRY_DSN[[:space:]]*=[[:space:]]*//p' "${ENV_FILE}" \
        | tail -n 1 | sed -E -e 's/[[:space:]]+$//' -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'$/\1/")"
fi

/usr/libexec/PlistBuddy -c "Delete :SentryDSN" "${PLIST}" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :SentryDSN string ${DSN}" "${PLIST}"

if [ -n "${DSN}" ]; then
    echo "SentryDSN set from .env"
else
    echo "No SENTRY_DSN in .env: this build sends no failure reports"
fi
