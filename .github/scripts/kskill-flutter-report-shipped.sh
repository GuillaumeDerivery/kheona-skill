# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# writes `<version> (<build>)` to the run summary, read back out of the built artifact rather than
# trusting what the lane asked for, and warns when it differs from pubspec.yaml's version name or from
# BUILD_NUMBER. Reporting only: a mismatch warns, it never fails a build that has already been uploaded.
#   android: the single .aab under build/app/outputs/bundle/ (its protobuf manifest, read with python3)
#   ios:     the single .ipa under ios/build/ (Info.plist, read with PlistBuddy), plus the Xcode used
# Bash 3.2-compatible (macOS). Usage: bash .github/scripts/kskill-flutter-report-shipped.sh android|ios
set -euo pipefail

platform="${1:?usage: kskill-flutter-report-shipped.sh android|ios}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
version_name="$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' pubspec.yaml | head -1)"

single() { # the one file matching a glob, or an error naming what was found
  local found=()
  shopt -s nullglob
  # shellcheck disable=SC2206 # why: the argument is a glob, expanded on purpose
  found=($1)
  shopt -u nullglob
  if [ "${#found[@]}" -ne 1 ]; then
    echo "::error::Expected exactly one $1, found ${#found[@]}: ${found[*]:-none}." >&2
    exit 1
  fi
  printf '%s\n' "${found[0]}"
}

case "$platform" in
  android)
    artifact="$(single 'build/app/outputs/bundle/*/*.aab')"
    label="Android"; destination="Play Console"
    # The AAB manifest is protobuf: each attribute is <name><0x1a><len><raw value>, so the value's string
    # sits right after its name. BUNDLE-METADATA does not carry the version.
    read -r shipped_version shipped_build < <(python3 - "$artifact" <<'PY'
import re, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    data = z.read('base/manifest/AndroidManifest.xml')
def attr(name):
    i = data.find(name.encode())
    if i < 0:
        return '?'
    m = re.match(rb'\x1a(.)([0-9A-Za-z._-]+)', data[i + len(name):])
    return m.group(2).decode() if m else '?'
print(attr('versionName'), attr('versionCode'))
PY
    )
    ;;
  ios)
    artifact="$(single 'ios/build/*.ipa')"
    label="iOS"; destination="TestFlight"
    work="$(mktemp -d)"
    unzip -q -o "$artifact" 'Payload/*.app/Info.plist' -d "$work"
    plist="$(find "$work/Payload" -maxdepth 2 -name Info.plist | head -1)"
    shipped_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
    shipped_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
    ;;
  *)
    echo "::error::Unknown platform '$platform' (android or ios)."
    exit 1
    ;;
esac

{
  echo "### $label → $destination"
  echo ""
  echo "\`$shipped_version ($shipped_build)\` from \`$artifact\` ($(du -h "$artifact" | cut -f1))"
  echo ""
  if [ "$shipped_version" != "$version_name" ]; then
    echo "> [!WARNING]"
    echo "> The shipped version name differs from pubspec.yaml ($version_name)."
  fi
  if [ -n "${BUILD_NUMBER:-}" ] && [ "$shipped_build" != "$BUILD_NUMBER" ]; then
    echo "> [!WARNING]"
    echo "> The shipped build number differs from the one this run derived ($BUILD_NUMBER)."
  fi
  if [ "$platform" = ios ]; then
    echo "Built with Xcode $(xcodebuild -version | head -1 | cut -d' ' -f2)."
  fi
} >> "$summary"
