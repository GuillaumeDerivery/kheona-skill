# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# prints the Flutter SDK version this repository pins, so CI installs the version the code was written
# with, never a channel. Run with bash, from the repository root (or pass it): bash kskill-flutter-version.sh [root]
# Output, in GITHUB_OUTPUT form:  version=3.47.4  channel=stable  source=.fvmrc
# Looks in order at: .fvmrc ("flutter"), .fvm/fvm_config.json ("flutterSdkVersion"), pubspec.yaml
# (`environment: flutter:` when it is one exact version). A channel name or a range is refused, not resolved.
set -euo pipefail

root=${1:-.}
cd "$root"

version="" source=""
if [ -f .fvmrc ]; then
  version=$(jq -r '.flutter // empty' .fvmrc) source=.fvmrc
elif [ -f .fvm/fvm_config.json ]; then
  version=$(jq -r '.flutterSdkVersion // empty' .fvm/fvm_config.json) source=.fvm/fvm_config.json
elif [ -f pubspec.yaml ]; then
  # The `flutter:` key directly under the top-level `environment:` block, quotes stripped.
  version=$(awk '
    /^[^[:space:]#]/ { in_env = ($0 ~ /^environment:/) ; next }
    in_env && /^[[:space:]]+flutter:/ { sub(/^[[:space:]]+flutter:[[:space:]]*/, ""); gsub(/["\047]/, ""); sub(/[[:space:]]*#.*$/, ""); print; exit }
  ' pubspec.yaml) source=pubspec.yaml
fi

if [ -z "$version" ]; then
  echo "::error::No Flutter version pinned. Add .fvmrc with {\"flutter\": \"<x.y.z>\"} (the version \`flutter --version\` prints), ." >&2
  exit 1
fi

if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  channel=stable
elif [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+\.pre$ ]]; then
  channel=beta
else
  echo "::error::$source pins Flutter \"$version\": not one exact version (a channel or a range moves on its own, )." >&2
  exit 1
fi

echo "version=$version"
echo "channel=$channel"
echo "source=$source"
