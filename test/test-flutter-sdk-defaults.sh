#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline tests for .github/scripts/kskill-flutter-sdk-defaults.sh, against fixture SDK sources laid out
# as in flutter_tools (the lines are the shapes Flutter 3.41-3.47 use).
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/.github/scripts/kskill-flutter-sdk-defaults.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
check() { # check <name> <fixed string expected in the output> <output>
  if grep -qF -- "$2" <<<"$3"; then pass=$((pass+1)); echo "ok   $1"
  else failn=$((failn+1)); echo "FAIL $1: no line '$2' in"; printf '     %s\n' "${3//$'\n'/$'\n'     }"; fi
}

sdk() { # sdk <dir> <gradle> <agp> <kotlin> <compileSdk> <xcode major> <ios target>
  local t="$1/packages/flutter_tools"
  mkdir -p "$t/lib/src/android" "$t/gradle/src/main/kotlin" "$t/lib/src/macos" "$t/templates/app/ios.tmpl/Runner.xcodeproj"
  cat > "$t/lib/src/android/gradle_utils.dart" <<EOF
const String templateDefaultGradleVersion = '$2';
const templateAndroidGradlePluginVersion = '$3';
const templateKotlinGradlePluginVersion = '$4';
const compileSdkVersionInt = $5;
const compileSdkVersion = '\$compileSdkVersionInt';
const maxKnownAndSupportedAgpVersion = '9.2';
EOF
  cat > "$t/gradle/src/main/kotlin/FlutterExtension.kt" <<EOF
    val compileSdkVersion: Int = $5
    val minSdkVersion: Int = 24
    val targetSdkVersion: Int = $5
    val ndkVersion: String = "28.2.13676358"
EOF
  echo "Version get xcodeRequiredVersion => Version($6, null, null);" > "$t/lib/src/macos/xcode.dart"
  echo "Version get xcodeRecommendedVersion => Version($(( $6 + 1 )), 2, null);" >> "$t/lib/src/macos/xcode.dart"
  printf '\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = %s;\n' "$7" "$7" > "$t/templates/app/ios.tmpl/Runner.xcodeproj/project.pbxproj.tmpl"
}
sdk "$T/old" 8.14 8.11.1 2.2.20 35 14 13.0
sdk "$T/new" 9.3.1 9.1.0 2.4.0 36 15 15.0

repo="$T/app"; mkdir -p "$repo/android/gradle/wrapper" "$repo/android/app" "$repo/ios/Runner.xcodeproj"
echo 'distributionUrl=https\://services.gradle.org/distributions/gradle-8.14-all.zip' > "$repo/android/gradle/wrapper/gradle-wrapper.properties"
cat > "$repo/android/settings.gradle.kts" <<'EOF'
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
EOF
cat > "$repo/android/app/build.gradle.kts" <<'EOF'
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
        minSdk = 26 // raised for a plugin
        targetSdk = flutter.targetSdkVersion
EOF
printf 'IPHONEOS_DEPLOYMENT_TARGET = 16.0;\nIPHONEOS_DEPLOYMENT_TARGET = 15.5;\n' > "$repo/ios/Runner.xcodeproj/project.pbxproj"
echo '{"workflows":{"cd":{"ios":{"xcode":"26.6"}}}}' > "$repo/.kheona.json"

out=$(bash "$SCRIPT" "$T/old" "$T/new" "$repo"); code=$?
check "exits 0"                                "|---|---|---|---|" "$out"
[ "$code" = 0 ] || { failn=$((failn+1)); echo "FAIL exit code $code"; }
check "Gradle old, new (changed), repo"        "| Gradle (wrapper) | 8.14 | **9.3.1** (changed) | 8.14 |" "$out"
check "AGP from settings.gradle.kts"           "| AGP (com.android.application) | 8.11.1 | **9.1.0** (changed) | 8.11.1 |" "$out"
check "Kotlin from settings.gradle.kts"        "| Kotlin (org.jetbrains.kotlin.android) | 2.2.20 | **2.4.0** (changed) | 2.2.20 |" "$out"
check "unchanged values stay plain"            "| Highest AGP the SDK supports | 9.2 | 9.2 | - |" "$out"
check "compileSdk from FlutterExtension.kt"    "| Android compileSdk | 35 | **36** (changed) | flutter.* (follows the SDK) |" "$out"
check "a number pinned by the app"             "| Android minSdk | 24 | 24 | 26 |" "$out"
check "Xcode required, with the delivery pin"  "| Xcode required (minimum) | 14 | **15** (changed) | 26.6 (workflows.cd.ios.xcode) |" "$out"
check "Xcode recommended with a minor"         "| Xcode recommended | 15.2 | **16.2** (changed) | - |" "$out"
check "iOS target: the lowest in the project"  "| iOS deployment target (app template) | 13.0 | **15.0** (changed) | 15.5 |" "$out"

out=$(bash "$SCRIPT" "$T/missing" "$T/new" "$T/nothing")
check "a missing SDK and repo print ?"         "| Gradle (wrapper) | ? | **9.3.1** (changed) | ? |" "$out"
check "no delivery pin: the image default"     "| Xcode required (minimum) | ? | **15** (changed) | runner image default |" "$out"
bash "$SCRIPT" only-one >/dev/null 2>&1; code=$?
if [ "$code" = 64 ]; then pass=$((pass+1)); echo "ok   a usage error exits 64"; else failn=$((failn+1)); echo "FAIL usage exit $code"; fi

echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
