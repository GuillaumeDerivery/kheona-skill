#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The repository check: callers, Renovate preset, undeclared workflows, the local rules.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); K="$HERE/scripts/kskill-repo-check.sh"; C="$HERE/scripts/kskill-callers.mjs"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failed=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1 (got: $2)"; fi; }
R=$T/r; mkdir -p "$R"; git -C "$R" init -q; cd "$R" || exit 1
echo '{}' > package.json; echo '{"role":"library"}' > .kheona.json
printf '.env\n.env.*\n!.env.example\n' > .gitignore
echo '{"extends":["github>owner/kheona-skill//renovate/default"]}' > renovate.json
node "$C" write --repo . --self owner/kheona-skill --sha 0123456789abcdef0123456789abcdef01234567 --version v1.0.0 > /dev/null
git add -A
out=$(bash "$K" --json . "$HERE"); rc=$?
check "complete: ok" "$rc $(jq -c '[.ok, .kheonaJson]' <<<"$out")" '^0 \[true,"valid"\]$'
rm renovate.json; git add -A
out=$(bash "$K" --json . "$HERE"); rc=$?
check "no renovate.json fails" "$rc $(jq -r '.errors[0].file' <<<"$out")" '^1 renovate.json$'
echo '{"extends":["github>owner/kheona-skill//renovate/default"]}' > renovate.json; rm .github/workflows/kskill-pr.yml; git add -A
out=$(bash "$K" --json . "$HERE"); rc=$?
check "a missing caller fails" "$rc $(jq -c '.callers[0].path' <<<"$out")" 'kskill-pr.yml'
node "$C" write --repo . --self owner/kheona-skill --sha 0123456789abcdef0123456789abcdef01234567 --version v1.0.0 > /dev/null
echo 'on: push' > .github/workflows/mine.yml; git add -A
out=$(bash "$K" --json . "$HERE"); rc=$?
check "an undeclared workflow fails" "$rc $(jq -c .undeclared <<<"$out")" '^1 .*mine.yml'
echo '{"role":"library","workflows":{"local":{"mine.yml":"our own"}}}' > .kheona.json; git add -A
out=$(bash "$K" --json . "$HERE"); rc=$?
check "... declared, it passes" "$rc" '^0$'
echo 'mongodb://user:pw@db1.corp/x' > config.json; git add -A
out=$(bash "$K" --json . "$HERE"); check "a committed MongoDB URI is listed" "$(jq -r '.mongo[0].path' <<<"$out")" 'config.json'
echo "$pass passed, $failed failed"; [ "$failed" = 0 ]
