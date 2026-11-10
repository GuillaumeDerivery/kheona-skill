#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The setup command against a fake gh: check only changes nothing; --apply writes what is missing; the store secrets
# a delivering app needs are named; a re-run of a finished setup only says ok.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); S="$HERE/scripts/kskill-setup.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failed=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1 (got: $2)"; fi; }
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$*" in
  "api repos/o/app/topics --jq"*) cat "$FAKE/topics" ;;
  "api -X PUT repos/o/app/topics"*) echo kheona-skill > "$FAKE/topics" ;;
  "api repos/o/app/actions/variables"*) cat "$FAKE/vars" ;;
  "variable set KSKILL_TOKEN_BROKER_URL"*) echo KSKILL_TOKEN_BROKER_URL > "$FAKE/vars" ;;
  "secret list"*) cat "$FAKE/secrets" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$T/bin/gh"
export FAKE="$T/fake" FAKE_LOG="$T/log" PATH="$T/bin:$PATH" KSKILL_SELF=owner/kheona-skill KSKILL_VERSION=v9.9.9 KSKILL_SHA=0123456789abcdef0123456789abcdef01234567
mkdir -p "$FAKE"; echo "" > "$FAKE/topics"; echo "" > "$FAKE/vars"; echo "" > "$FAKE/secrets"
R="$T/app"; mkdir -p "$R"; git -C "$R" init -q -b main; printf 'name: app\nversion: 1.2.3+4\n' > "$R/pubspec.yaml"
git -C "$R" -c user.name=t -c user.email=t@t add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm init
run() { (cd "$T" && bash "$S" "$@" o/app "$R" 2>&1); }

out=$(run); rc=$?
check "check only: todo, exit 1" "$rc" '^1$'
check "... names each missing piece" "$out" 'todo  \.kheona\.json missing'
check "... and changes nothing" "$(git -C "$R" status --porcelain)" '^$'
check "... nor the topic" "$(cat "$FAKE/topics")" '^$'
out=$(KSKILL_TOKEN_BROKER_URL=https://broker.example.com run --apply </dev/null); rc=$?
check "--apply: .kheona.json written" "$(jq -r .role "$R/.kheona.json")" '^project$'
check "... the topic added" "$(cat "$FAKE/topics")" '^kheona-skill$'
check "... the manifest seeded on several lines at pubspec's version" "$(cat "$R/.release-please-manifest.json")" $'^\\{\n  "\\.": "1\\.2\\.3"\n\\}$'
check "... release-type dart" "$(jq -r '.packages["."]["release-type"]' "$R/release-please-config.json")" '^dart$'
check "... the callers written at the version" "$(grep -ho '@0123456789abcdef0123456789abcdef01234567 # v9.9.9' "$R"/.github/workflows/kskill-*.yml | sort -u)" 'v9\.9\.9'
check "... the Renovate preset pinned" "$(jq -r '.extends[0]' "$R/renovate.json")" '^github>owner/kheona-skill//renovate/default#v9\.9\.9$'
check "... the broker variable set" "$(cat "$FAKE/vars")" 'KSKILL_TOKEN_BROKER_URL'
check "... the store secrets named, not in a terminal" "$out" 'todo  secret ASC_KEY_ID: the App Store Connect API key.s id'
check "... no secret value written anywhere" "$(grep -c 'secret set' "$T/log")" '^0$'
check "... the PR left to a person when it cannot push" "$out" 'todo  the PR'
echo 'ANDROID_KEYSTORE_BASE64 CM_KEYSTORE_PASSWORD CM_KEY_ALIAS CM_KEY_PASSWORD PLAY_STORE_JSON_KEY_BASE64 IOS_DIST_CERTIFICATE_P12_BASE64 IOS_DIST_CERTIFICATE_PASSWORD ASC_KEY_ID ASC_ISSUER_ID ASC_API_KEY_BASE64' > "$FAKE/secrets"
out=$(run)
check "the old CM_* names alone: the ANDROID_* ones asked for" "$out" 'todo  secret ANDROID_KEY_ALIAS: the upload key.s alias in the keystore \(the same value as CM_KEY_ALIAS'
check "... each of the three" "$(grep -c 'todo  secret ANDROID_KEY' <<<"$out")" '^3$'
echo 'ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD PLAY_STORE_JSON_KEY_BASE64 IOS_DIST_CERTIFICATE_P12_BASE64 IOS_DIST_CERTIFICATE_PASSWORD ASC_KEY_ID ASC_ISSUER_ID ASC_API_KEY_BASE64' > "$FAKE/secrets"
out=$(run)
check "a re-run with the secrets set: ok" "$out" 'ok    secrets \(10 needed, all set\)'
check "... and the callers ok" "$out" 'ok    callers at v9\.9\.9'
echo "$pass passed, $failed failed"; [ "$failed" = 0 ]
