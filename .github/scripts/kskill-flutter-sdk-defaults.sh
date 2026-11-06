# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# /what a Flutter SDK move changes for an app. Prints a Markdown table of the values the SDK itself
# sets (the Android Gradle/AGP/Kotlin triple, compileSdk/minSdk/targetSdk/NDK behind `flutter.*`, the Xcode it
# requires, the iOS deployment target of its app template), old SDK beside new SDK beside this repository.
# Read off the SDK's own sources, never off upstream: flutter_tools' gradle_utils.dart, FlutterExtension.kt,
# macos/xcode.dart and the app template's project.pbxproj.tmpl. A file or value it cannot find prints "?".
# Informational: it always exits 0 (64 on a usage error). The inbox's refresh-flutter job puts it in its PR.
# Usage: bash kskill-flutter-sdk-defaults.sh <old flutter root> <new flutter root> [repository root]
#   A "flutter root" only needs the four files above at their SDK paths (the workflow fetches the old SDK's
#   from GitHub at its tag rather than installing it).
set -uo pipefail

if [ $# -lt 2 ]; then
  echo "usage: kskill-flutter-sdk-defaults.sh <old flutter root> <new flutter root> [repository root]" >&2
  exit 64
fi
OLD=$1 NEW=$2 REPO=${3:-.}

tools=packages/flutter_tools
gu() { echo "$1/$tools/lib/src/android/gradle_utils.dart"; }
fe() { echo "$1/$tools/gradle/src/main/kotlin/FlutterExtension.kt"; }
xc() { echo "$1/$tools/lib/src/macos/xcode.dart"; }
pbx() { echo "$1/$tools/templates/app/ios.tmpl/Runner.xcodeproj/project.pbxproj.tmpl"; }

# `const [Type ]name = 'v';` or `const name = v;` in gradle_utils.dart; a `$reference` is not a value.
dconst() {
  local v
  v=$(sed -nE "s/^const ([A-Za-z<>]+ )?$2 = '?([^';]*)'?;.*/\2/p" "$(gu "$1")" 2>/dev/null | head -1)
  case "$v" in '$'*) v="" ;; esac
  printf '%s' "$v"
}
# `val name: Int = 36` / `val name: String = "28.2"` in FlutterExtension.kt: what `flutter.<name>` resolves to.
fext() { sed -nE "s/.*val $2: [A-Za-z]+ = \"?([^\"]+)\"?.*/\1/p" "$(fe "$1")" 2>/dev/null | head -1; }
sdk_int() { local v; v=$(fext "$1" "$2"); [ -n "$v" ] || v=$(dconst "$1" "$3"); [ -n "$v" ] || v=$(dconst "$1" "$4"); printf '%s' "$v"; }
xcode_version() { # Version get xcodeRequiredVersion => Version(15, null, null);
  sed -nE "s/.*$2 => Version\(([0-9]+), *([0-9]+|null), *([0-9]+|null)\).*/\1.\2.\3/p" "$(xc "$1")" 2>/dev/null |
    head -1 | sed -E 's/\.null//g'
}
ios_target() { grep -oE 'IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+' "$(pbx "$1")" 2>/dev/null | grep -oE '[0-9.]+$' | sort -V | head -1; }

line() { printf '%s\n' "$1"; } # each row is one line, whether or not the command printed a newline
values() { # values <root>: one line per row, in the order of LABELS
  line "$(dconst "$1" templateDefaultGradleVersion)"
  line "$(dconst "$1" templateAndroidGradlePluginVersion)"
  line "$(dconst "$1" templateKotlinGradlePluginVersion)"
  line "$(dconst "$1" maxKnownAndSupportedAgpVersion)"
  line "$(sdk_int "$1" compileSdkVersion compileSdkVersionInt compileSdkVersion)"
  line "$(sdk_int "$1" minSdkVersion minSdkVersionInt minSdkVersion)"
  line "$(sdk_int "$1" targetSdkVersion targetSdkVersionInt targetSdkVersion)"
  line "$(sdk_int "$1" ndkVersion ndkVersion ndkVersion)"
  line "$(xcode_version "$1" xcodeRequiredVersion)"
  line "$(xcode_version "$1" xcodeRecommendedVersion)"
  line "$(ios_target "$1")"
}

# --- this repository ----------------------------------------------------------------------
wrapper="$REPO/android/gradle/wrapper/gradle-wrapper.properties"
settings="$REPO/android/settings.gradle.kts"; [ -f "$settings" ] || settings="$REPO/android/settings.gradle"
app="$REPO/android/app/build.gradle.kts"; [ -f "$app" ] || app="$REPO/android/app/build.gradle"
plugin_version() { sed -n "s/.*[\"']$1[\"'][)]* *version *[\"']\([^\"']*\)[\"'].*/\1/p" "$settings" 2>/dev/null | head -1; }
app_setting() { # `minSdk = flutter.minSdkVersion` reads the SDK; a number is pinned by the app.
  local line
  line=$(grep -E "^[[:space:]]*$1[[:space:]=]" "$app" 2>/dev/null | head -1)
  if [ -z "$line" ]; then echo "-"
  elif grep -q 'flutter\.' <<<"$line"; then echo "flutter.* (follows the SDK)"
  else sed -E "s/^[[:space:]]*$1[[:space:]]*=?[[:space:]]*//; s/[[:space:]]*(\/\/.*)?$//; s/\"//g" <<<"$line"
  fi
}
repo_values() {
  local xcode
  line "$(sed -n 's/.*gradle-\([0-9][0-9.]*\)-[a-z]*\.zip.*/\1/p' "$wrapper" 2>/dev/null | head -1)"
  line "$(plugin_version 'com\.android\.application')"
  line "$(plugin_version 'org\.jetbrains\.kotlin\.android')"
  line "-"
  line "$(app_setting compileSdk)"
  line "$(app_setting minSdk)"
  line "$(app_setting targetSdk)"
  line "$(app_setting ndkVersion)"
  xcode=$(jq -r '.workflows.cd.ios.xcode // empty' "$REPO/.kheona.json" 2>/dev/null || true)
  if [ -n "$xcode" ]; then line "$xcode (workflows.cd.ios.xcode)"; else line "runner image default"; fi
  line "-"
  line "$(grep -oE 'IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+' "$REPO/ios/Runner.xcodeproj/project.pbxproj" 2>/dev/null |
    grep -oE '[0-9.]+$' | sort -V | head -1)"
}

LABELS='Gradle (wrapper)
AGP (com.android.application)
Kotlin (org.jetbrains.kotlin.android)
Highest AGP the SDK supports
Android compileSdk
Android minSdk
Android targetSdk
Android NDK
Xcode required (minimum)
Xcode recommended
iOS deployment target (app template)'

old_v=$(values "$OLD"); new_v=$(values "$NEW"); repo_v=$(repo_values)
echo "| Setting | Old SDK | New SDK | This repository |"
echo "|---|---|---|---|"
i=0
while IFS= read -r label; do
  i=$((i + 1))
  o=$(sed -n "${i}p" <<<"$old_v"); n=$(sed -n "${i}p" <<<"$new_v"); r=$(sed -n "${i}p" <<<"$repo_v")
  o=${o:-?} n=${n:-?} r=${r:-?}
  if [ "$o" != "$n" ]; then n="**$n** (changed)"; fi
  echo "| $label | $o | $n | $r |"
done <<<"$LABELS"
exit 0
