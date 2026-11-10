#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline tests for .github/scripts/kskill-check-lib-versions.mjs: registry packages lib declares must be locked at
# lib's version; a package lib takes from git, a URL or a path has no registry version and is not compared.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); S="$HERE/.github/scripts/kskill-check-lib-versions.mjs"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failed=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1 (got: $2)"; fi; }
lock() { jq -n --argjson p "$1" '{packages: ($p | with_entries(.key |= "node_modules/" + .) | map_values({version: .}))}'; }
mkdir -p "$T/submodules/lib"
echo '{"name":"lib","dependencies":{"express":"^5.0.0"},"devDependencies":{"kheona-skill":"github:owner/kheona-skill#aaaa","tools":"owner/tools#v1"}}' > "$T/submodules/lib/package.json"
lock '{"express":"5.3.0","kheona-skill":"1.0.3","tools":"2.0.0"}' > "$T/submodules/lib/package-lock.json"
run() { (cd "$T" && node "$S" 2>&1; echo "rc=$?"); }
lock '{"express":"5.3.0","kheona-skill":"1.0.4","tools":"9.9.9"}' > "$T/package-lock.json"
check "git and owner/repo dependencies are not compared" "$(run)" 'OK: 1 packages.*rc=0'
lock '{"express":"5.2.0","kheona-skill":"1.0.3"}' > "$T/package-lock.json"
check "a registry package at another version fails" "$(run)" 'express: this project 5\.2\.0, lib 5\.3\.0.*rc=1'
lock '{"kheona-skill":"1.0.3"}' > "$T/package-lock.json"
check "only git dependencies shared: nothing compared, refused" "$(run)" 'nothing was compared.*rc=2'
echo "lib-versions: $pass passed, $failed failed"; [ "$failed" = 0 ]
