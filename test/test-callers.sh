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
check "service: its callers" "$(ls "$R/.github/workflows" | tr '\n' ' ')" '^kskill-claude.yml kskill-deploy.yml kskill-inbox.yml kskill-main.yml kskill-pr.yml kskill-release-please.yml $'
check "production deploy: pinned by the version tag" "$(grep 'uses:' "$R/.github/workflows/kskill-deploy.yml")" "uses: owner/kheona-skill/.github/workflows/kskill-deploy.yml@v1.2.3$"
check "... started by a version tag" "$(grep -A1 'push:' "$R/.github/workflows/kskill-deploy.yml" | tail -1)" 'tags: \["v\*"\]'
check "... no environment input" "$(grep -c 'environment' "$R/.github/workflows/kskill-deploy.yml")" '^0$'
check "... reads the release PR" "$(grep -c 'pull-requests: read' "$R/.github/workflows/kskill-deploy.yml")" '^1$'
check "no custom job by default" "$(grep -c 'custom:' "$R/.github/workflows/kskill-deploy.yml")" '^0$'
check "pinned by SHA, the tag as a comment" "$(grep 'uses:' "$R/.github/workflows/kskill-pr.yml")" "uses: owner/kheona-skill/.github/workflows/kskill-pr.yml@$SHA # v1.2.3$"
check "no caller names its stack (the shared workflows read it)" "$(grep -l 'stack:' "$R"/.github/workflows/*.yml | wc -l | tr -d ' ')" '^0$'
check "main: one shared workflow, whatever the stack" "$(grep 'uses:' "$R/.github/workflows/kskill-main.yml")" "kskill-main.yml@$SHA # v1.2.3$"
check "... the stack: node, deploys staging" "$(node "$C" stack --repo "$R" | tr '\n' ' ')" '^stack=node deploys=true $'
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
check "Flutter: delivery, no ship" "$(ls "$R/.github/workflows" | tr '\n' ' ')" '^kskill-claude.yml kskill-deliver.yml kskill-inbox.yml kskill-main.yml kskill-pr.yml kskill-release-please.yml $'
check "... main is the same shared workflow" "$(grep -c 'kskill-main.yml@' "$R/.github/workflows/kskill-main.yml")" '^1$'
for pair in ANDROID_KEYSTORE_PASSWORD:CM_KEYSTORE_PASSWORD ANDROID_PLAY_STORE_JSON_KEY_BASE64:PLAY_STORE_JSON_KEY_BASE64 \
  APPLE_DIST_CERTIFICATE_P12_BASE64:IOS_DIST_CERTIFICATE_P12_BASE64 APPLE_DIST_CERTIFICATE_PASSWORD:IOS_DIST_CERTIFICATE_PASSWORD \
  APPLE_API_KEY_ID:ASC_KEY_ID APPLE_API_ISSUER_ID:ASC_ISSUER_ID APPLE_API_KEY_BASE64:ASC_API_KEY_BASE64; do
  new=${pair%%:*} old=${pair#*:}
  check "... the delivery gets $new and its old name $old" \
    "$(grep -cE "^      ($new: \\$\\{\\{ secrets\\.$new|$old: \\$\\{\\{ secrets\\.$old) \\}\\}$" "$R/.github/workflows/kskill-deliver.yml")" '^2$'
done
check "... the stack: flutter, deploys nothing from main" "$(node "$C" stack --repo "$R" | tr '\n' ' ')" '^stack=flutter deploys=false $'
check "... delivery pinned by the version tag" "$(grep 'uses:' "$R/.github/workflows/kskill-deliver.yml")" '@v1.2.3$'
node "$C" check --repo "$R"; check "Flutter: check passes with a tag pin" "$?" '^0$'
sed -i.bak 's/@v1.2.3$/@v1.2.4/' "$R/.github/workflows/kskill-deliver.yml"
out=$(node "$C" check --repo "$R" --json); check "callers at two versions fail" "$?:$out" '^1:.*different versions'
R=$T/rn; mkdir -p "$R"; echo '{}' > "$R/package.json"; echo '{"role":"library"}' > "$R/.kheona.json"
echo '{"extends": ["github>owner/kheona-skill//renovate/default"]}' > "$R/renovate.json"; w "$R"
check "the preset is pinned at the version" "$(cat "$R/renovate.json")" 'renovate/default#v1.2.3"'
node "$C" check --repo "$R"; check "... and the check passes" "$?" '^0$'
sed -i.bak 's/#v1.2.3//' "$R/renovate.json"
out=$(node "$C" check --repo "$R" --json); check "a preset on the default branch fails" "$?:$out" '^1:.*renovate.json'
R=$T/cu; mkdir -p "$R"; echo '{}' > "$R/package.json"
echo '{"role":"project","workflows":{"cd":{"target":"custom","custom":{"workflow":"ship-it.yml"},"staging":{},"prod":{}}}}' > "$R/.kheona.json"; w "$R"
check "custom target: the deploy hands over" "$(grep -A8 '^  custom:' "$R/.github/workflows/kskill-deploy.yml" | tr '\n' ' ')" "if: needs.call.outputs.deploy == 'custom'.*uses: ./.github/workflows/ship-it.yml"
check "... main hands over staging too" "$(grep -c 'uses: ./.github/workflows/ship-it.yml' "$R/.github/workflows/kskill-main.yml")" '^1$'
node "$C" check --repo "$R"; check "custom target: check passes" "$?" '^0$'
if command -v actionlint >/dev/null; then
  out=$(cd "$R" && actionlint -ignore 'could not read reusable workflow' -ignore 'ship-it.yml' .github/workflows/kskill-*.yml 2>&1); check "custom callers lint" "$?:$out" '^0:'
fi
echo '{"workflows":{"cd":{"target":"custom","custom":{"workflow":"kskill-x.yml"},"prod":{}}}}' > "$R/.kheona.json"
out=$(node "$C" write --repo "$R" --self owner/kheona-skill --sha $SHA --version v1.2.3 2>&1); check "custom workflow named kskill-*: refused" "$?" '^1$'
R=$T/lib; mkdir -p "$R"; echo '{}' > "$R/package.json"; echo '{"role":"library"}' > "$R/.kheona.json"; w "$R"
check "a library: release-please and its forks' notice, no deploy" "$(ls "$R/.github/workflows" | tr '\n' ' ')" '^kskill-claude.yml kskill-inbox.yml kskill-main.yml kskill-pr.yml kskill-release-please.yml kskill-sync-upstream.yml $'
check "... the stack: node, deploys nothing from main" "$(node "$C" stack --repo "$R" | tr '\n' ' ')" '^stack=node deploys=false $'
echo '{"role":"library","workflows":{"cd":{"target":"custom","prod":{}}}}' > "$R/.kheona.json"; w "$R"
check "... no staging to hand over, even with a custom target" "$(grep -c 'custom:' "$R/.github/workflows/kskill-main.yml")" '^0$'
R=$T/py; mkdir -p "$R"; : > "$R/Pipfile"; w "$R"
check "Python: a service" "$(node "$C" stack --repo "$R" | tr '\n' ' ')" '^stack=python deploys=true $'
R=$T/nostack; mkdir -p "$R"; echo '{"role":"project"}' > "$R/.kheona.json"; w "$R"
check "no stack: @claude, the inbox and release-please, no CI" "$(ls "$R/.github/workflows" | tr '\n' ' ')" '^kskill-claude.yml kskill-inbox.yml kskill-release-please.yml $'
out=$(node "$C" stack --repo "$R" 2>&1); check "... and the gate's stack read fails, never passes silently" "$?:$out" '^1:::error::No stack'
R=$T/inf; mkdir -p "$R"; echo '{"role":"infra"}' > "$R/.kheona.json"; w "$R"
check "infra: the PR alone" "$(ls "$R/.github/workflows" | tr '\n' ' ')" '^kskill-pr.yml $'
check "... the stack: infra, no stack named in the caller" "$(node "$C" stack --repo "$R" | head -1):$(grep -c 'stack:' "$R/.github/workflows/kskill-pr.yml")" '^stack=infra:0$'
out=$(node "$C" write --repo "$T" --self owner/kheona-skill --sha abc --version v1.2.3 2>&1); check "a short SHA is refused" "$?" '^64$'
out=$(node "$C" write --repo "$T" --self owner/kheona-skill --sha $SHA --version v1 2>&1); check "a version that is not vX.Y.Z is refused" "$?" '^64$'
echo "$pass passed, $failed failed"; [ "$failed" = 0 ]
