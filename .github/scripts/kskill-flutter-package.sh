# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# Verifies one local package of a Flutter repository (e.g. packages/<name>, a path dependency of the app):
# install from its own lockfile, analyze, and run its tests with coverage when it has a test/ directory.
# Run with bash from the repository root: bash kskill-flutter-package.sh <package-path> [fail-under]
# A Flutter package (depends on the flutter SDK) follows the Flutter exception: coverage collected, never gated
# . A pure-Dart package gets a threshold when [fail-under] is given, through package:coverage,
# which it must then list in dev_dependencies. Coverage lands in <package-path>/coverage/lcov.info.
set -euo pipefail

pkg=${1:?usage: kskill-flutter-package.sh <package-path> [fail-under]}
fail_under=${2:-}
if [ ! -f "$pkg/pubspec.yaml" ]; then
  echo "::error::$pkg/pubspec.yaml not found: fix .kheona.json workflows.ci.packages." >&2
  exit 1
fi
cd "$pkg"

flutter_pkg=false
grep -qE '^[[:space:]]+sdk:[[:space:]]*flutter[[:space:]]*$' pubspec.yaml && flutter_pkg=true

echo "::group::$pkg: install from the lockfile"
if [ ! -f pubspec.lock ]; then
  echo "::error::$pkg has no committed pubspec.lock." >&2
  exit 1
fi
if $flutter_pkg; then flutter pub get --enforce-lockfile; else dart pub get --enforce-lockfile; fi
echo "::endgroup::"

echo "::group::$pkg: analyze"
if $flutter_pkg; then flutter analyze; else dart analyze --fatal-infos; fi
echo "::endgroup::"

if [ ! -d test ]; then
  echo "::notice::$pkg has no test/ directory: nothing to run (applies to it like to the app)."
  exit 0
fi

echo "::group::$pkg: test"
if $flutter_pkg; then
  [ -z "$fail_under" ] || echo "::warning::$pkg is a Flutter package: failUnder is ignored (Flutter coverage is never gated, )."
  flutter test --coverage
elif grep -qE '^[[:space:]]+coverage:' pubspec.yaml; then
  dart run coverage:test_with_coverage ${fail_under:+--fail-under="$fail_under"}
else
  if [ -n "$fail_under" ]; then
    echo "::error::$pkg sets failUnder but does not list package:coverage in dev_dependencies, so nothing could enforce it." >&2
    exit 1
  fi
  echo "::warning::$pkg is a pure-Dart package without package:coverage: tests run, no coverage report ."
  dart test
fi
echo "::endgroup::"
