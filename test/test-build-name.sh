#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline tests for .github/scripts/kskill-build-name.sh, on throwaway git repositories.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); S="$HERE/.github/scripts/kskill-build-name.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failed=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1 (got: $2)"; fi; }
R=$T/r; git init -q -b main "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
c() { printf 'name: app\nversion: %s\n' "$1" > "$R/pubspec.yaml"; g add -A; g commit -q --allow-empty -m "$2"; }
run() { : > "$T/env"; (cd "$R" && VERSION=${VERSION:-} GITHUB_ENV="$T/env" bash "$S" 2>&1; echo "rc=$?"; cat "$T/env"); }

c 0.1.0+1 init
check "no release yet: pubspec's version" "$(run)" 'BUILD_NAME=0\.1\.0$'
c 0.2.0 'chore: release 0.2.0'; g tag v0.2.0
check "a test build of the released commit: refused" "$(run)" 'is the release v0\.2\.0.*rc=1'
check "... and no name exported" "$(run | grep -c BUILD_NAME=)" '^0$'
check "the release itself: its version" "$(VERSION=v0.2.0 run)" 'BUILD_NAME=0\.2\.0$'
g commit -q --allow-empty -m 'feat: x'
check "a test build after a release: the next patch" "$(run)" 'BUILD_NAME=0\.2\.1$'
g tag v0.10.0 HEAD~1 2>/dev/null; g tag latest
check "... after the highest version reachable, tags that are not versions ignored" "$(run)" 'BUILD_NAME=0\.10\.1$'
check "a release whose pubspec disagrees: refused" "$(VERSION=v0.3.0 run)" 'pubspec\.yaml says version 0\.2\.0.*rc=1'
check "a VERSION that is not vX.Y.Z: refused" "$(VERSION=0.2.0 run)" 'rc=1'
git clone -q --depth 1 "file://$R" "$T/shallow" 2>/dev/null
check "a shallow clone: refused" "$(cd "$T/shallow" && bash "$S" 2>&1; echo "rc=$?")" 'fetch-depth: 0.*rc=1'

echo "build-name: $pass passed, $failed failed"; [ "$failed" = 0 ]
