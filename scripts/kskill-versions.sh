#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# — remote version audit. Answers "is anything we pin still current?" by asking
# the authoritative upstream, not by reading what is installed.
#
#   versions.sh            report every component it can resolve for this repo
#   versions.sh --machine  only the toolchain installed on this Mac (no repo needed)
#
# Every source below was run before it shipped. If one starts returning nothing, that is
# a broken source, not a passing check — the report says UNKNOWN and you go look.
#
# THE DERIVED RULE (do not lose this): Gradle, AGP and Kotlin for a Flutter app are NOT
# "whatever is newest". They are read off the installed Flutter SDK's
# flutter_tools/lib/src/android/gradle_utils.dart. The newest-available column below is
# INFORMATIONAL ONLY — matching it is a bug, not an upgrade. See flutter-toolchain.md.

set -uo pipefail
MACHINE_ONLY=0; [ "${1:-}" = "--machine" ] && MACHINE_ONLY=1
CURL="curl -s --max-time 20"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 1

STALE_F="$(mktemp)"; trap 'rm -f "$STALE_F"' EXIT
row() { printf '| %-22s | %-14s | %-14s | %-16s | %s\n' "$1" "$2" "$3" "$4" "$5"; }
hdr() { echo; echo "| Component              | In project     | On this Mac    | Latest upstream  | Verdict"; \
        echo "|------------------------|----------------|----------------|------------------|--------"; }
verdict() { # $1 have  $2 want
  [ -z "$1" ] || [ "$1" = "-" ] && { echo "UNKNOWN — could not resolve"; return; }
  [ -z "$2" ] && { echo "UNKNOWN — upstream did not answer"; return; }
  if [ "$1" = "$2" ]; then echo "current"
  else echo x >> "$STALE_F"; echo "**STALE → $2**"; fi
}

# ---------------- remote sources (each verified) ----------------
FLUTTER_LATEST="$($CURL https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json \
  | jq -r '.releases|map(select(.channel=="stable"))|.[0].version' 2>/dev/null)"
DART_LATEST="$($CURL https://storage.googleapis.com/dart-archive/channels/stable/release/latest/VERSION | jq -r '.version' 2>/dev/null)"
GRADLE_NEWEST="$($CURL https://services.gradle.org/versions/current | jq -r '.version' 2>/dev/null)"
AGP_NEWEST="$($CURL https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/maven-metadata.xml \
  | grep -oE '<version>[^<]+' | sed 's/<version>//' | grep -vE 'alpha|beta|rc' | sort -V | tail -1)"
KOTLIN_NEWEST="$($CURL https://api.github.com/repos/JetBrains/kotlin/releases/latest | jq -r '.tag_name' 2>/dev/null | sed 's/^v//')"
XC="$($CURL https://xcodereleases.com/data.json | jq -r '[.[]|select(.version.release.release==true)][0]|"\(.version.number)|\([.sdks.iOS[]?.number]|first)"' 2>/dev/null)"
XCODE_LATEST="${XC%%|*}"; IOSSDK_LATEST="${XC##*|}"
ANDROID_REPO="$($CURL https://dl.google.com/android/repository/repository2-3.xml)"
API_NEWEST="$(printf '%s' "$ANDROID_REPO" | grep -oE '<api-level>[0-9]+' | sed 's/<api-level>//' | sort -n | tail -1)"
BUILDTOOLS_NEWEST="$(printf '%s' "$ANDROID_REPO" | grep -oE 'path="build-tools;[0-9.]+"' | sed 's/.*;//;s/"//' | sort -V | tail -1)"

# ---------------- local ----------------
FLUTTER_LOCAL="$(flutter --version 2>/dev/null | head -1 | awk '{print $2}')"
DART_LOCAL="$(dart --version 2>&1 | awk '{print $4}')"
XCODE_LOCAL="$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')"
IOSSDK_LOCAL="$(xcodebuild -showsdks 2>/dev/null | grep -oE 'iphoneos[0-9.]+' | sed 's/iphoneos//' | sort -V | tail -1)"

# ---------------- Flutter's DERIVED android triple (the real target) ----------------
GU=""; [ -n "$FLUTTER_LOCAL" ] && GU="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)" 2>/dev/null || command -v flutter)")")/packages/flutter_tools/lib/src/android/gradle_utils.dart"
derived() { [ -f "$GU" ] && grep -oE "$1 = '[^']+'" "$GU" | head -1 | sed "s/.*'\\(.*\\)'/\\1/"; }
GRADLE_WANT="$(derived templateDefaultGradleVersion)"
AGP_WANT="$(derived templateAndroidGradlePluginVersion)"
KOTLIN_WANT="$(derived templateKotlinGradlePluginVersion)"
AGP_MAX="$(derived maxKnownAndSupportedAgpVersion)"

# ---------------- project ----------------
PROJ_FLUTTER=""; PROJ_GRADLE=""; PROJ_AGP=""; PROJ_KOTLIN=""; PROJ_COMPILE=""; PROJ_TARGET=""; COMPILE_NOTE=""; TARGET_NOTE=""; PROJ_IOS=""
if [ $MACHINE_ONLY -eq 0 ]; then
  # The pin is often factored into a composite action rather than sitting in the workflow.
  # A pin can sit on the `flutter-version:` line, or as a composite action's input `default:`
  # several lines below it. Look at any .github file that mentions Flutter at all.
  while IFS= read -r f; do
    v="$(grep -oE '(flutter-version|default):[[:space:]]*"?[0-9]+\.[0-9]+\.[0-9]+' "$f" \
         | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    [ -n "$v" ] && { PROJ_FLUTTER="$v"; break; }
  done < <(grep -rlE 'flutter-version|flutter-action' .github/ 2>/dev/null)
  [ -z "$PROJ_FLUTTER" ] && PROJ_FLUTTER="$(jq -r '.flutter // empty' .fvmrc 2>/dev/null)"
  [ -z "$PROJ_FLUTTER" ] && grep -rqE 'channel: *stable' .github/ 2>/dev/null \
    && PROJ_FLUTTER="channel:stable"   # FAIL: a channel is not a version
  PROJ_GRADLE="$(grep -oE 'gradle-[0-9.]+' android/gradle/wrapper/gradle-wrapper.properties 2>/dev/null | head -1 | sed 's/gradle-//')"
  PROJ_AGP="$(grep -oE '"com\.android\.application"\) version "[0-9.]+' android/settings.gradle.kts 2>/dev/null | grep -oE '[0-9.]+$')"
  PROJ_KOTLIN="$(grep -oE '"org\.jetbrains\.kotlin\.android"\) version "[0-9.]+' android/settings.gradle.kts 2>/dev/null | grep -oE '[0-9.]+$')"
  # Reading these from flutter.* is the correct state — resolve the number Flutter supplies.
  BG=android/app/build.gradle.kts; [ -f "$BG" ] || BG=android/app/build.gradle
  FE="$(dirname "$GU")/../../../gradle/src/main/kotlin/FlutterExtension.kt"
  fdsl() { [ -f "$FE" ] && grep -oE "$1: Int = [0-9]+" "$FE" | grep -oE '[0-9]+$'; }
  if grep -q 'compileSdk *= *flutter\.' "$BG" 2>/dev/null; then
    PROJ_COMPILE="$(fdsl compileSdkVersion)"; COMPILE_NOTE=" (flutter.*)"
  else
    PROJ_COMPILE="$(grep -oE 'compileSdk *=? *[0-9]+' "$BG" 2>/dev/null | grep -oE '[0-9]+')"; COMPILE_NOTE=" (hardcoded)"
  fi
  if grep -q 'targetSdk *= *flutter\.' "$BG" 2>/dev/null; then
    PROJ_TARGET="$(fdsl targetSdkVersion)"; TARGET_NOTE=" (flutter.*)"
  else
    PROJ_TARGET="$(grep -oE 'targetSdk *=? *[0-9]+' "$BG" 2>/dev/null | grep -oE '[0-9]+')"; TARGET_NOTE=" (hardcoded)"
  fi
  PROJ_IOS="$(grep -oE 'IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+' ios/Runner.xcodeproj/project.pbxproj 2>/dev/null | grep -oE '[0-9.]+' | sort -V | head -1)"
fi

echo "# — remote version audit"
echo
echo "Repo: \`$ROOT\`   ·   $(date +%Y-%m-%d)"

hdr
if [ "${PROJ_FLUTTER:-}" = "channel:stable" ]; then
  echo x >> "$STALE_F"
  FV="**FAIL — a channel is not a version; pin ${FLUTTER_LATEST:-the SDK}**"
else FV="$(verdict "${FLUTTER_LOCAL:-}" "${FLUTTER_LATEST:-}")"; fi
row "Flutter SDK"       "${PROJ_FLUTTER:--}" "${FLUTTER_LOCAL:--}" "${FLUTTER_LATEST:--}" "$FV"
row "Dart SDK"          "-"                  "${DART_LOCAL:--}"    "${DART_LATEST:--}"    "$(verdict "${DART_LOCAL:-}" "${DART_LATEST:-}")"
row "Xcode"             "-"                  "${XCODE_LOCAL:--}"   "${XCODE_LATEST:--}"   "$(verdict "${XCODE_LOCAL:-}" "${XCODE_LATEST:-}")"
row "iOS SDK"           "${PROJ_IOS:--} (min)" "${IOSSDK_LOCAL:--}" "${IOSSDK_LATEST:--}" "$(verdict "${IOSSDK_LOCAL:-}" "${IOSSDK_LATEST:-}")"
row "Android compileSdk" "${PROJ_COMPILE:--}${COMPILE_NOTE:-}" "-"        "${API_NEWEST:--}"     "$([ -n "${PROJ_COMPILE:-}" ] && echo "derived — correct; newest API is ${API_NEWEST:-?}" || echo "UNKNOWN")"
row "Android targetSdk"  "${PROJ_TARGET:--}${TARGET_NOTE:-}"  "-"        "${API_NEWEST:--}"     "$([ -n "${PROJ_TARGET:-}" ] && echo "derived — check against Play's deadline for NEW releases" || echo "UNKNOWN")"
row "Android build-tools" "-"                 "-"                  "${BUILDTOOLS_NEWEST:--}" "informational"

echo
echo "## Android triple — target is DERIVED from the Flutter SDK, not 'newest'"
echo
echo "| Component | In project | Flutter says (THE TARGET) | Newest upstream (do NOT chase) | Verdict"
echo "|-----------|------------|---------------------------|-------------------------------|--------"
printf '| Gradle    | %-10s | %-25s | %-29s | %s\n' "${PROJ_GRADLE:--}" "${GRADLE_WANT:--}" "${GRADLE_NEWEST:--}" "$(verdict "${PROJ_GRADLE:-}" "${GRADLE_WANT:-}")"
printf '| AGP       | %-10s | %-25s | %-29s | %s\n' "${PROJ_AGP:--}"    "${AGP_WANT:--}"    "${AGP_NEWEST:--}"    "$(verdict "${PROJ_AGP:-}" "${AGP_WANT:-}")"
printf '| Kotlin    | %-10s | %-25s | %-29s | %s\n' "${PROJ_KOTLIN:--}" "${KOTLIN_WANT:--}" "${KOTLIN_NEWEST:--}" "$(verdict "${PROJ_KOTLIN:-}" "${KOTLIN_WANT:-}")"
echo
echo "AGP ceiling this SDK makes claims about: \`maxKnownAndSupportedAgpVersion = ${AGP_MAX:-?}\`."
echo "Anything above it is outside Flutter's supported range whatever Dependabot opened. The three move"
echo "as a set (AGP 9 requires Gradle 9.x) — bump the Flutter SDK, then re-read these three off it."

echo
echo "## How to fix"
echo
echo "**On this Mac:**"
echo '```bash'
echo "flutter upgrade                      # also moves the bundled Dart SDK"
echo "softwareupdate --list                # Xcode ships via the App Store / developer.apple.com"
echo "#   Xcode ${XCODE_LOCAL:-?} → ${XCODE_LATEST:-?}: install it, then: sudo xcode-select -s /Applications/Xcode.app"
echo "sdkmanager --install 'platforms;android-${API_NEWEST:-?}' 'build-tools;${BUILDTOOLS_NEWEST:-?}'"
echo '```'
echo
echo "**In the project:** bump \`flutter-version:\` in every workflow and \`.fvmrc\` to match the SDK you"
echo "just installed, then re-read the Android triple off the new SDK and update"
echo "\`gradle-wrapper.properties\` and \`android/settings.gradle.kts\` to *those* values — never to the"
echo "newest-upstream column. Then rebuild both platforms clean before opening the PR."
echo
STALE="$(wc -l < "$STALE_F" | tr -d " ")"
if [ "$STALE" -eq 0 ]; then echo "**PASS** — nothing resolved as stale."
else echo "**$STALE component(s) behind.** A deliberate one-behind is a pass — record the reason and the"
     echo "target version on a tracking issue. Not knowing is the failure."; fi
