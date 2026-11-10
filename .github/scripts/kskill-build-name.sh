# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# stacks/flutter.md K2: the store build name (CFBundleShortVersionString / versionName), from git like the build number.
#   a release (VERSION=vX.Y.Z)  X.Y.Z, and pubspec.yaml's version must say the same (release-please writes it)
#   a test build (main)          the next patch after the highest release tag reachable: v1.4.0 -> 1.4.1. A store closes a
#                                version once it is released, so a test build never reuses the release's name. Before
#                                any release, pubspec.yaml's version as is.
# A test build of a commit a release tag points at is refused: that build is the release's, ship the tag instead.
# Both lanes run it on the same commit, so both get one name. Exports BUILD_NAME to $GITHUB_ENV and prints it; a lane
# passes it to `flutter build ... --build-name "$BUILD_NAME"` (optional for a lane: without it, pubspec's version).
# Usage: bash .github/scripts/kskill-build-name.sh   (from the repository root, full history: fetch-depth 0)
set -euo pipefail

semver='^([0-9]+)\.([0-9]+)\.([0-9]+)$'
pubspec=$(awk '/^version:/ { v = $2; gsub(/["\047]/, "", v); sub(/\+.*/, "", v); print v; exit }' pubspec.yaml 2>/dev/null || true)
export_name() {
  if [ -n "${GITHUB_ENV:-}" ]; then echo "BUILD_NAME=$1" >> "$GITHUB_ENV"; fi
  echo "Build name $1 ($2)."
}

if [ -n "${VERSION:-}" ]; then
  [[ "$VERSION" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || { echo "::error::VERSION '$VERSION' is not vX.Y.Z."; exit 1; }
  name=${BASH_REMATCH[1]}
  [ "$pubspec" = "$name" ] || { echo "::error::pubspec.yaml says version ${pubspec:-<none>}, the tag $VERSION: the release PR writes both. Fix pubspec.yaml or the release-please config."; exit 1; }
  export_name "$name" "the release $VERSION"
  exit 0
fi

[ "$(git rev-parse --is-shallow-repository)" = false ] || { echo "::error::Shallow clone: the last release tag cannot be found. The checkout needs fetch-depth: 0."; exit 1; }
at=$(git tag --points-at HEAD --list 'v[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)
if [ -n "$at" ]; then
  echo "::error::$(git rev-parse --short HEAD) is the release $at: a test build would repeat it. Ship the release by hand on its tag, or merge a change first."
  exit 1
fi
last=$(git tag --merged HEAD --list 'v[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)
if [[ "${last#v}" =~ $semver ]]; then
  export_name "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))" "a test build after $last"
elif [[ "$pubspec" =~ $semver ]]; then
  export_name "$pubspec" "a test build, no release yet: pubspec.yaml's version"
else
  echo "::error::No release tag and no X.Y.Z version in pubspec.yaml: nothing to name the build after."
  exit 1
fi
