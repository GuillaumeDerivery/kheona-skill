# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# uploads this build's debug files to Sentry with `dart run sentry_dart_plugin`, in the job that built
# the artifact (symbols are per-build; a release whose symbols were never uploaded stays unreadable).
# SENTRY_RELEASE / SENTRY_DIST are set to what the app reports at runtime, `<appId>@<version>+<build>` and
# `<build>`, not the plugin's pubspec-name default, so release health and regressions attach to real events.
# A missing SENTRY_AUTH_TOKEN does not block the release (the DSN is in the binary; this only uploads
# symbols): it is a warning on the step and in the run summary, never a silent skip.
# Env: SENTRY_AUTH_TOKEN (secret), KSKILL_SENTRY_ORG, KSKILL_SENTRY_PROJECT, KSKILL_SENTRY_URL (may be empty),
#      KSKILL_SENTRY_APP_ID, BUILD_NUMBER.
# Usage: bash .github/scripts/kskill-flutter-sentry-upload.sh
set -euo pipefail

: "${BUILD_NUMBER:?BUILD_NUMBER is not set: the build-number step runs first}"
version_name="$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' pubspec.yaml | head -1)"
if [ -z "$version_name" ]; then
  echo "::error::No version: line in pubspec.yaml."
  exit 1
fi

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "::warning::Debug symbols NOT uploaded: secret SENTRY_AUTH_TOKEN is not set. Native frames in this build stay unsymbolicated, permanently."
  {
    echo "> [!WARNING]"
    echo "> **Debug symbols were not uploaded** for this build: secret \`SENTRY_AUTH_TOKEN\` is not set."
    echo "> Symbols are per-build, so this cannot be fixed after the fact, only in the next release."
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi

export SENTRY_ORG="${KSKILL_SENTRY_ORG:?KSKILL_SENTRY_ORG is not set}"
export SENTRY_PROJECT="${KSKILL_SENTRY_PROJECT:?KSKILL_SENTRY_PROJECT is not set}"
if [ -n "${KSKILL_SENTRY_URL:-}" ]; then export SENTRY_URL="$KSKILL_SENTRY_URL"; fi
export SENTRY_RELEASE="${KSKILL_SENTRY_APP_ID:?KSKILL_SENTRY_APP_ID is not set}@${version_name}+${BUILD_NUMBER}"
export SENTRY_DIST="$BUILD_NUMBER"

echo "Uploading to $SENTRY_ORG/$SENTRY_PROJECT under release $SENTRY_RELEASE (dist $SENTRY_DIST)."
dart run sentry_dart_plugin
