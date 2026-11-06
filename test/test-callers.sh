#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The caller files: what each kind of repository needs, their content, the check, and that they lint.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); C="$HERE/scripts/kskill-callers.mjs"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failed=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1 (got: $2)"; fi; }
SHA=0123456789abcdef0123456789abcdef01234567
w() { node "$C" write --repo "$1" --self owner/kheona-skill --sha $SHA --version v1.2.3 > /dev/null; }
# a service
R=$T/svc; mkdir -p "$R"; echo '{}' > "$R/package.json"
echo '{"role":"project","workflows":{"cd":{"staging":{},"prod":{}}}}' > "$R/.kheona.json"; w "$R"
check "service: its callers" "$(ls "$R/.github/workflows" | tr '\n' ' ')" '^kskill-claude.yml kskill-deploy.yml kskill-inbox.yml kskill-main.yml kskill-pr.yml kskill-ship.yml $'
check "pinned by SHA, the tag as a comment" "$(grep 'uses:' "$R/.github/workflows/kskill-pr.yml")" "uses: owner/kheona-skill/.github/workflows/kskill-pr.yml@$SHA # v1.2.3$"
check "the stack is an input" "$(grep -c 'stack: node' "$R/.github/workflows/kskill-pr.yml")" '^1$'
check "grants the OIDC identity" "$(grep -c 'id-token: write' "$R/.github/workflows/kskill-pr.yml")" '^1$'
check "no App key, no inherit" "$(grep -rlE 'PRIVATE_KEY|secrets: inherit' "$R/.github/workflows" | wc -l | tr -d ' ')" '^0$'
node "$C" check --repo "$R"; check "check: exact: exit 0" "$?" '^0$'
if command -v actionlint >/dev/null; then
  out=$(cd "$R" && actionlint -ignore 'could not read reusable workflow' .github/workflows/*.yml 2>&1); check "callers lint" "$?:$out" '^0:'
fi
echo '# edited' >> "$R/.github/workflows/kskill-pr.yml"
node "$C" check --repo "$R" 2>/dev/null; check "an edited caller fails" "$?" '^1$'
w "$R"; rm "$R/.github/workflows/kskill-main.yml"
out=$(node "$C" check --repo "$R" --json); check "a missing one fails, by name" "$?:$out" '^1:.*kskill-main.yml.*missing'
w "$R"; : > "$R/.github/workflows/kskill-old.yml"
out=$(node "$C" check --repo "$R" --json); check "an unknown kskill file fails" "$?:$out" '^1:.*unknown'
# others
R=$T/fl; mkdir -p "$R"; : > "$R/pubspec.yaml"; echo '{"role":"project"}' > "$R/.kheona.json"; w "$R"
check "Flutter: delivery" "$(ls "$R/.github/workflows" | tr '\n' ' ')" 'kskill-deliver.yml .*kskill-ship.yml'
R=$T/lib; mkdir -p "$R"; echo '{}' > "$R/package.json"; echo '{"role":"library"}' > "$R/.kheona.json"; w "$R"
check "a library: release-please, no deploy" "$(ls "$R/.github/workflows" | tr '\n' ' ')" '^kskill-claude.yml kskill-inbox.yml kskill-main.yml kskill-pr.yml kskill-release-please.yml $'
R=$T/inf; mkdir -p "$R"; echo '{"role":"infra"}' > "$R/.kheona.json"; w "$R"
check "infra: the PR alone" "$(ls "$R/.github/workflows" | tr '\n' ' ')" '^kskill-pr.yml $'
check "... with the infra gate" "$(grep -c 'stack: infra' "$R/.github/workflows/kskill-pr.yml")" '^1$'
out=$(node "$C" write --repo "$T" --self owner/kheona-skill --sha abc --version v1 2>&1); check "a short SHA is refused" "$?" '^64$'
echo "$pass passed, $failed failed"; [ "$failed" = 0 ]
