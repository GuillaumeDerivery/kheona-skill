#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The setup command against a fake gh: check only changes nothing; --apply writes what is missing; the store secrets
# a delivering app needs are walked through (what, where, the exact command, the pitfalls) and never read or set by
# the script; either name of an Android signing secret counts; a person's answers are remembered; a stopped run
# resumes; a re-run of a finished setup only says ok.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); S="$HERE/scripts/kskill-setup.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failed=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1 (got: $2)"; fi; }
mkdir -p "$T/bin"
# The fake: topics, variables and secret names in files; each `secret list` after the first also lists $FAKE/later
# (a person setting a secret in another terminal while the walkthrough waits).
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$*" in
  "api repos/o/app/topics --jq"*) cat "$FAKE/topics" ;;
  "api -X PUT repos/o/app/topics"*) echo kheona-skill > "$FAKE/topics" ;;
  "api repos/o/app/actions/variables/"*) n=${2##*/}; [ -f "$FAKE/var-$n" ] && cat "$FAKE/var-$n" || exit 1 ;;
  "api repos/o/app/actions/variables"*) cat "$FAKE/vars" ;;
  "variable set "*) printf '%s' "$7" > "$FAKE/var-$3"; echo "$3" >> "$FAKE/vars"; tr '\n' ' ' < "$FAKE/vars" > "$FAKE/vars.1"; mv "$FAKE/vars.1" "$FAKE/vars" ;;
  "api orgs/o/installations"*) exit 1 ;;
  "api users/o --jq"*) echo User ;;
  "secret list"*) n=$(( $(cat "$FAKE/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/n"
    { cat "$FAKE/secrets"; [ "$n" -ge 2 ] && [ -f "$FAKE/later" ] && cat "$FAKE/later"; } | tr '\n' ' ' ;;
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
check "... asks for KSKILL_BOT to check the App" "$out" 'todo  the App: set KSKILL_BOT'
check "... and changes nothing" "$(git -C "$R" status --porcelain)" '^$'
check "... nor the topic" "$(cat "$FAKE/topics")" '^$'
out=$(KSKILL_BOT='app-bot[bot]' KSKILL_TOKEN_BROKER_URL=https://broker.example.com run --apply </dev/null); rc=$?
check "--apply: .kheona.json written" "$(jq -r .role "$R/.kheona.json")" '^project$'
check "... the topic added" "$(cat "$FAKE/topics")" '^kheona-skill$'
check "... the App left to a person on a personal account, with where to look" "$out" 'todo  the App app-bot installed on o/app: https://github\.com/settings/installations'
check "... the manifest seeded on several lines at pubspec's version" "$(cat "$R/.release-please-manifest.json")" $'^\\{\n  "\\.": "1\\.2\\.3"\n\\}$'
check "... release-type dart" "$(jq -r '.packages["."]["release-type"]' "$R/release-please-config.json")" '^dart$'
check "... the callers written at the version" "$(grep -ho '@0123456789abcdef0123456789abcdef01234567 # v9.9.9' "$R"/.github/workflows/kskill-*.yml | sort -u)" 'v9\.9\.9'
check "... their header names the setup command exactly" "$(head -1 "$R/.github/workflows/kskill-pr.yml")" 'Do not edit: run scripts/kskill-setup\.sh --apply again\.$'
check "... the Renovate preset pinned" "$(jq -r '.extends[0]' "$R/renovate.json")" '^github>owner/kheona-skill//renovate/default#v9\.9\.9$'
check "... both variables set" "$(cat "$FAKE/vars")" 'KSKILL_BOT KSKILL_TOKEN_BROKER_URL'
check "... each store secret named" "$out" 'todo  secret APPLE_API_KEY_ID'
check "... with where to find it" "$out" 'Users and Access, Integrations, App Store Connect API, Team Keys'
check "... the exact command for a value (gh asks for it)" "$out" 'Set it: gh secret set APPLE_API_ISSUER_ID --repo o/app   \(gh asks'
check "... the exact command for a file" "$out" "base64 < cert\\.p12 \\| tr -d '\\\\n' \\| gh secret set APPLE_DIST_CERTIFICATE_P12_BASE64 --repo o/app"
check "... the .p12's password: set it if there is one" "$out" 'exported with one, set it too: gh secret set APPLE_DIST_CERTIFICATE_PASSWORD --repo o/app'
check "... none: leave the secret unset" "$out" 'Without one, leave APPLE_DIST_CERTIFICATE_PASSWORD unset \(GitHub cannot store an empty secret\)'
check "... and it is never asked for on its own" "$(grep -c 'todo  secret APPLE_DIST_CERTIFICATE_PASSWORD' <<<"$out")" '^0$'
check "... macOS's openssl is LibreSSL" "$out" '/usr/bin/openssl is LibreSSL and cannot read a modern PKCS#12'
check "... Homebrew's OpenSSL, -legacy for RC2" "$out" 'openssl@3\)/bin/openssl" pkcs12 -in cert\.p12 -noout -info, adding -legacy'

check "... keytool from Android Studio" "$out" 'Android Studio\.app/Contents/jbr/Contents/Home/bin/keytool'
check "... the signing secrets under their ANDROID_ and APPLE_ names" "$out" 'todo  secret ANDROID_KEY_ALIAS'
check "... no secret set, no value read" "$(grep -c 'secret set' "$T/log")" '^0$'
check "... the script never reads a value" "$(grep -cE 'read -[a-z]*s' "$S")" '^0$'
check "... the PR left to a person when it cannot push" "$out" 'todo  the PR'
check "... with the command that sets it" "$out" 'todo  secret ANDROID_KEY_ALIAS'$'\n''.*'$'\n''.*'$'\n''  Set it: gh secret set ANDROID_KEY_ALIAS'

# A person at the keyboard: the App confirmed (remembered), one secret set while it waits, one skipped, then q.
echo 'ANDROID_KEYSTORE_BASE64 ANDROID_PLAY_STORE_JSON_KEY_BASE64 APPLE_DIST_CERTIFICATE_P12_BASE64 APPLE_DIST_CERTIFICATE_PASSWORD APPLE_API_KEY_ID APPLE_API_ISSUER_ID' > "$FAKE/secrets"
echo 'ANDROID_KEYSTORE_PASSWORD' > "$FAKE/later"; rm -f "$FAKE/n"
out=$(printf 'y\n\ns\nq\n' | KSKILL_SETUP_TTY=1 run --apply); rc=$?
check "interactive: the App confirmed and remembered" "$out" 'done  App app-bot installed \(confirmed'
check "... in the clone's .git, not in a file git tracks" "$(cat "$R/.git/kskill-setup.state")" '^app-installed o/app app-bot$'
check "... the secret set while it waited: done" "$out" 'done  secret ANDROID_KEYSTORE_PASSWORD'
check "... the skipped one: todo" "$out" 'todo  secret ANDROID_KEY_ALIAS: skipped'
check "... q stops: the rest left for the next run" "$out" 'todo  secret ANDROID_KEY_PASSWORD: not set yet \(run this again to continue\)'$'\n''todo  secret APPLE_API_KEY_BASE64: not set yet'
check "... exit 1" "$rc" '^1$'
check "... still no secret set by the script" "$(grep -c 'secret set' "$T/log")" '^0$'

# An old name (before v2.9.0) no longer counts: its new name is asked for, and the leftover said, to delete.
echo 'ANDROID_KEYSTORE_BASE64 CM_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD ANDROID_PLAY_STORE_JSON_KEY_BASE64 APPLE_DIST_CERTIFICATE_P12_BASE64 ASC_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_BASE64' > "$FAKE/secrets"
rm -f "$FAKE/later"
out=$(run)
check "an old name alone: the new one missing" "$(grep -oE 'todo  secret [A-Z0-9_]+$' <<<"$out" | tr '\n' ' ')" '^todo  secret ANDROID_KEYSTORE_PASSWORD todo  secret APPLE_API_KEY_ID $'
check "... each old one said, with its new name and the command that deletes it" "$out" 'note  secret ASC_KEY_ID is no longer read: APPLE_API_KEY_ID replaces it; once APPLE_API_KEY_ID is set, gh secret delete ASC_KEY_ID --repo o/app'
check "... the two old ones, no new one" "$(grep -oE 'note  secret [A-Z0-9_]+' <<<"$out" | sort | tr '\n' ' ')" \
  '^note  secret ASC_KEY_ID note  secret CM_KEYSTORE_PASSWORD $'
check "... nothing deleted by the script" "$(grep -c 'secret delete' "$T/log")" '^0$'

# Done: the new names set (no .p12 password), an old one left beside them said, and the App is not asked again.
echo 'ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD ANDROID_PLAY_STORE_JSON_KEY_BASE64 APPLE_DIST_CERTIFICATE_P12_BASE64 APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_BASE64 IOS_DIST_CERTIFICATE_PASSWORD' > "$FAKE/secrets"
out=$(KSKILL_SETUP_TTY=1 run --apply </dev/null)
check "a re-run with the secrets set, no .p12 password: ok" "$out" 'ok    secrets \(9 needed, all set\)'
check "... the old .p12 password said, to delete" "$(grep '^note  secret' <<<"$out")" '^note  secret IOS_DIST_CERTIFICATE_PASSWORD is no longer read: APPLE_DIST_CERTIFICATE_PASSWORD replaces it'
check "... the App not asked again" "$out" 'ok    App app-bot installed \(confirmed by a person\)'
check "... the variables read back from the repository" "$out" 'ok    variable KSKILL_BOT'
check "... and the callers ok" "$out" 'ok    callers at v9\.9\.9'
echo 'ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD ANDROID_PLAY_STORE_JSON_KEY_BASE64 APPLE_DIST_CERTIFICATE_P12_BASE64 APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_BASE64' > "$FAKE/secrets"
out=$(run)
check "the new names only: ok, nothing said" "$(grep -c '^note' <<<"$out"):$(grep -o 'ok    secrets.*' <<<"$out")" '^0:ok    secrets \(9 needed, all set\)$'
echo "$pass passed, $failed failed"; [ "$failed" = 0 ]
