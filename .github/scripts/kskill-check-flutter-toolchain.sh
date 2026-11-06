# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# the Android Gradle / AGP / Kotlin triple is derived from the installed Flutter SDK, never chosen.
# Reads the SDK's own template constants (packages/flutter_tools/lib/src/android/gradle_utils.dart) and
# compares them with what android/ declares. Exit 0 in sync, 1 on drift, 2 when the SDK cannot be found.
# Run with bash after any `flutter upgrade`, and in CI: bash .github/scripts/kskill-check-flutter-toolchain.sh [root]
# Handles settings.gradle (Groovy) and settings.gradle.kts.
set -euo pipefail

root=$(cd "${1:-.}" && pwd)

flutter_root=$(flutter --version --machine 2>/dev/null | jq -r '.flutterRoot // empty' || true)
if [ -z "$flutter_root" ] || [ ! -d "$flutter_root" ]; then
  echo "::error::Cannot locate the Flutter SDK (flutter --version --machine): is flutter on PATH?" >&2
  exit 2
fi
gradle_utils="$flutter_root/packages/flutter_tools/lib/src/android/gradle_utils.dart"
if [ ! -f "$gradle_utils" ]; then
  echo "::error::$gradle_utils not found: unexpected Flutter SDK layout." >&2
  exit 2
fi

# --- what the installed SDK expects -------------------------------------------------------
sdk_const() { sed -n "s/^const $1 = '\([^']*\)';.*/\1/p" "$gradle_utils" | head -1; }
want_gradle=$(sdk_const templateDefaultGradleVersion)
want_agp=$(sdk_const templateAndroidGradlePluginVersion)
want_kotlin=$(sdk_const templateKotlinGradlePluginVersion)
max_agp=$(sdk_const maxKnownAndSupportedAgpVersion)

# --- what this repository declares --------------------------------------------------------
wrapper="$root/android/gradle/wrapper/gradle-wrapper.properties"
settings="$root/android/settings.gradle.kts"
[ -f "$settings" ] || settings="$root/android/settings.gradle"
for f in "$wrapper" "$settings"; do
  if [ ! -f "$f" ]; then
    echo "::error::$f not found. A repository without an Android build sets .kheona.json workflows.ci.androidToolchain to false." >&2
    exit 1
  fi
done
have_gradle=$(sed -n 's/.*gradle-\([0-9][0-9.]*\)-[a-z]*\.zip.*/\1/p' "$wrapper" | head -1)
# Matches `id "x" version "y"` (Groovy) and `id("x") version "y"` (Kotlin DSL).
plugin_version() { sed -n "s/.*[\"']$1[\"'][)]* *version *[\"']\([^\"']*\)[\"'].*/\1/p" "$settings" | head -1; }
have_agp=$(plugin_version 'com\.android\.application')
have_kotlin=$(plugin_version 'org\.jetbrains\.kotlin\.android')
# No declaration means AGP's built-in Kotlin, which supplies its own KGP: that is drift too (AGP 9.1.0's
# built-in KGP 2.2.10 is below what Flutter's Gradle plugin accepts), so it is reported, not skipped.
[ -n "$have_kotlin" ] || have_kotlin="(none declared)"

# --- report -------------------------------------------------------------------------------
drift=0
row() {
  local mark=ok
  if [ "$2" != "$3" ]; then mark=DRIFT; drift=1; fi
  printf '  %-8s %-22s %-14s %s\n' "$1" "$2" "$3" "$mark"
}
echo "Flutter SDK: $flutter_root ($(flutter --version --machine 2>/dev/null | jq -r '.frameworkVersion // "?"'))"
printf '  %-8s %-22s %-14s\n' "" "in repo" "SDK expects"
row Gradle "$have_gradle" "$want_gradle"
row AGP "$have_agp" "$want_agp"
row Kotlin "$have_kotlin" "$want_kotlin"
echo "  This SDK's highest known and supported AGP: $max_agp (newer upstream releases are not targets)."

if [ "$drift" -eq 0 ]; then
  echo "In sync."
  exit 0
fi
cat >&2 <<EOF
::error::The Android toolchain has drifted from the installed Flutter SDK.
Set all three together, they are not independent (AGP 9 requires Gradle 9.x):
  android/gradle/wrapper/gradle-wrapper.properties   Gradle -> $want_gradle
  $(basename "$settings")   com.android.application -> $want_agp, org.jetbrains.kotlin.android -> $want_kotlin
Then verify with a real build (flutter build apk --debug), not only flutter analyze.
To raise them, raise the Flutter SDK; never chase the newest upstream release.
EOF
exit 1
