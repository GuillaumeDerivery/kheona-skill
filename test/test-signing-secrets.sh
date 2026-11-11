#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The delivery's secrets' rename: Android ones start with ANDROID_, Apple ones with APPLE_ (from CM_*, a Codemagic
# leftover, PLAY_STORE_*, IOS_DIST_* and ASC_*). The delivery takes both names, the new one wins, the lane gets both,
# and the callers pass both, until every repository holds the new ones. And the iOS .p12's password is optional: GitHub
# cannot store an empty secret, so a .p12 exported without one leaves it unset.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); cd "$HERE" || exit 64
W=.github/workflows/kskill-deliver-flutter.yml
pass=0 failed=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1 (got: $2)"; fi; }
y() { ruby -ryaml -e 'w = YAML.load_file(ARGV[0]); puts eval(ARGV[1])' "$W" "$1"; }
step() { y "w['jobs']['$1']['steps'].find { |s| s['name'] == '$2' }['env'].map { |k, v| \"#{k}=#{v}\" }.join(\"\\n\")"; }
PAIRS="ANDROID_KEYSTORE_PASSWORD:CM_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS:CM_KEY_ALIAS ANDROID_KEY_PASSWORD:CM_KEY_PASSWORD
  ANDROID_PLAY_STORE_JSON_KEY_BASE64:PLAY_STORE_JSON_KEY_BASE64 APPLE_DIST_CERTIFICATE_P12_BASE64:IOS_DIST_CERTIFICATE_P12_BASE64
  APPLE_DIST_CERTIFICATE_PASSWORD:IOS_DIST_CERTIFICATE_PASSWORD APPLE_API_KEY_ID:ASC_KEY_ID APPLE_API_ISSUER_ID:ASC_ISSUER_ID
  APPLE_API_KEY_BASE64:ASC_API_KEY_BASE64"

declared=$(y '(w["on"] || w[true])["workflow_call"]["secrets"].keys.sort.join(" ")')
for pair in $PAIRS; do
  new=${pair%%:*} old=${pair#*:}
  check "the delivery takes $new" "$declared" "(^| )$new( |$)"
  check "... and still $old" "$declared" "(^| )$old( |$)"
done
check "the callers pass every secret the delivery takes" \
  "$(jq -r '."kskill-deliver-flutter.yml".secrets | sort | join(" ")' .github/callers.json)" "^$declared$"
check "every new name starts with ANDROID_ or APPLE_" \
  "$(tr ' ' '\n' <<<"$declared" | grep -vE '^(ANDROID|APPLE)_' | grep -vE '^(CM|PLAY_STORE|IOS_DIST|ASC)_' | tr '\n' ' ')" '^SENTRY_AUTH_TOKEN $'

# Where a secret's value is used, the new name first; the lane gets both names of each value.
either() { echo "\\\$\\{\\{ secrets\\.$1 \\|\\| secrets\\.$2 \\}\\}"; }
build=$(step android 'Build and upload to Google Play')
for n in KEYSTORE_PASSWORD KEY_ALIAS KEY_PASSWORD; do
  check "the Android lane gets ANDROID_$n, the new secret first" "$build" "(^|"$'\n'")ANDROID_$n=$(either ANDROID_$n CM_$n)"
  check "... and CM_$n, the same value" "$build" "(^|"$'\n'")CM_$n=$(either ANDROID_$n CM_$n)"
done
build=$(step ios 'Build and upload to TestFlight')
for pair in APPLE_API_KEY_ID:ASC_KEY_ID APPLE_API_ISSUER_ID:ASC_ISSUER_ID; do
  new=${pair%%:*} old=${pair#*:}
  check "the iOS lane gets $new, the new secret first" "$build" "(^|"$'\n'")$new=$(either "$new" "$old")"
  check "... and $old, the same value" "$build" "(^|"$'\n'")$old=$(either "$new" "$old")"
done
check "the Play key decoded from the new secret first" "$(step android 'Decode the Play Console key')" \
  "^PLAY_STORE_JSON_KEY_BASE64=$(either ANDROID_PLAY_STORE_JSON_KEY_BASE64 PLAY_STORE_JSON_KEY_BASE64)$"
cert=$(step ios 'Import the distribution certificate')
check "the .p12 from the new secret first" "$cert" "CERTIFICATE_BASE64=$(either APPLE_DIST_CERTIFICATE_P12_BASE64 IOS_DIST_CERTIFICATE_P12_BASE64)"
check "... its password too" "$cert" "CERTIFICATE_PASSWORD=$(either APPLE_DIST_CERTIFICATE_PASSWORD IOS_DIST_CERTIFICATE_PASSWORD)"
check "the .p8 from the new secret first" "$(step ios 'Write the App Store Connect key')" \
  "^APPLE_API_KEY_BASE64=$(either APPLE_API_KEY_BASE64 ASC_API_KEY_BASE64)$"
for v in ANDROID_KEYSTORE_PATH CM_KEYSTORE_PATH ANDROID_PLAY_STORE_JSON_KEY_PATH PLAY_STORE_JSON_KEY_PATH APPLE_API_KEY_FILEPATH ASC_KEY_FILEPATH; do
  check "the lane gets the file path $v" "$(grep -c "echo \"$v=\\\$[A-Z_]*PATH\" >> \"\\\$GITHUB_ENV\"" "$W")" '^1$'
done

# The secrets check, run as the step runs: the new name wins, an old one alone warns, both missing fail by new name.
script=$(y 'w["jobs"]["android"]["steps"].find { |s| s["name"] == "Check the signing secrets" }["run"]')
run() { env -i PATH="$PATH" REPO=owner/repo DRY_RUN=false ANDROID_KEYSTORE_BASE64=k "$@" bash -c "$script" 2>&1; echo "rc=$?"; }
out=$(run ANDROID_KEYSTORE_PASSWORD=a ANDROID_KEY_ALIAS=b ANDROID_KEY_PASSWORD=c ANDROID_PLAY_STORE_JSON_KEY_BASE64=p)
check "android, the new names: passes, no warning" "$out" '^rc=0$'
out=$(run CM_KEYSTORE_PASSWORD=a CM_KEY_ALIAS=b CM_KEY_PASSWORD=c PLAY_STORE_JSON_KEY_BASE64=p)
check "android, the old names alone: passes" "$out" 'rc=0$'
check "... with a deprecation warning each" "$(grep -c '::warning::.* is deprecated' <<<"$out")" '^4$'
check "... naming the new one" "$out" '::warning::PLAY_STORE_JSON_KEY_BASE64 is deprecated: set ANDROID_PLAY_STORE_JSON_KEY_BASE64 to the same value, then delete PLAY_STORE_JSON_KEY_BASE64\.'
out=$(run ANDROID_KEYSTORE_PASSWORD=a ANDROID_KEY_ALIAS=b CM_KEY_PASSWORD=c ANDROID_PLAY_STORE_JSON_KEY_BASE64=p)
check "android, a mix: passes, one warning" "$(grep -c '::warning::' <<<"$out"):$(tail -1 <<<"$out")" '^1:rc=0$'
out=$(run ANDROID_KEYSTORE_PASSWORD=a)
check "android, missing: fails by the new names" "$out" 'Missing repository secret\(s\): ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD ANDROID_PLAY_STORE_JSON_KEY_BASE64\.'
check "... exit 1" "$(tail -1 <<<"$out")" '^rc=1$'

# iOS: the same, and the .p12's password is optional, the .p12 itself is not.
check "the delivery takes APPLE_DIST_CERTIFICATE_PASSWORD, not required" \
  "$(y '(w["on"] || w[true])["workflow_call"]["secrets"]["APPLE_DIST_CERTIFICATE_PASSWORD"]["required"]')" '^false$'
script=$(y 'w["jobs"]["ios"]["steps"].find { |s| s["name"] == "Check the signing secrets" }["run"]')
ios() { env -i PATH="$PATH" REPO=owner/repo DRY_RUN=false "$@" bash -c "$script" 2>&1; echo "rc=$?"; }
NEW="APPLE_API_KEY_ID=i APPLE_API_ISSUER_ID=s APPLE_API_KEY_BASE64=k"
OLD="ASC_KEY_ID=i ASC_ISSUER_ID=s ASC_API_KEY_BASE64=k"
# shellcheck disable=SC2086 # why: one NAME=value per word
{
out=$(ios $NEW APPLE_DIST_CERTIFICATE_P12_BASE64=c APPLE_DIST_CERTIFICATE_PASSWORD=p)
check "ios, the new names, .p12 and password: passes, nothing said" "$out" '^rc=0$'
out=$(ios $OLD IOS_DIST_CERTIFICATE_P12_BASE64=c IOS_DIST_CERTIFICATE_PASSWORD=p)
check "ios, the old names alone: passes" "$(tail -1 <<<"$out")" '^rc=0$'
check "... with a deprecation warning each, the password's included" "$(grep -c '::warning::.* is deprecated' <<<"$out")" '^5$'
check "... naming the new one" "$out" '::warning::ASC_KEY_ID is deprecated: set APPLE_API_KEY_ID to the same value, then delete ASC_KEY_ID\.'
check "... no notice: the old password counts" "$(grep -c '::notice::' <<<"$out")" '^0$'
out=$(ios $NEW APPLE_DIST_CERTIFICATE_P12_BASE64=c)
check "ios: .p12 without a password: passes" "$(tail -1 <<<"$out")" '^rc=0$'
check "... saying it imports with an empty password" "$out" '::notice::APPLE_DIST_CERTIFICATE_PASSWORD is not set: the \.p12 is imported with an empty password\.'
check "... no warning" "$(grep -c '::warning::' <<<"$out")" '^0$'
out=$(ios $NEW IOS_DIST_CERTIFICATE_P12_BASE64=c)
check "ios: the old .p12 alone, no password: passes, a warning and the notice" \
  "$(grep -c '::warning::IOS_DIST_CERTIFICATE_P12_BASE64 is deprecated' <<<"$out"):$(grep -c '::notice::' <<<"$out"):$(tail -1 <<<"$out")" '^1:1:rc=0$'
out=$(ios $NEW APPLE_DIST_CERTIFICATE_PASSWORD=p)
check "ios: no .p12: fails by its new name" "$out" 'Missing repository secret\(s\): APPLE_DIST_CERTIFICATE_P12_BASE64\.'
check "... exit 1" "$(tail -1 <<<"$out")" '^rc=1$'
out=$(ios)
check "ios: nothing: the new names, never the password" "$out" 'secret\(s\): APPLE_DIST_CERTIFICATE_P12_BASE64 APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_BASE64\. '
check "... exit 1" "$(tail -1 <<<"$out")" '^rc=1$'
}

# The import, run as the step runs with a stand-in for macOS's security: like the real one (checked on macOS 26 for
# OpenSSL's -legacy and default AES files, and unencrypted ones), it refuses an OpenSSL .p12's empty password. The
# step re-encodes the file under a generated password with this OpenSSL, and the stand-in opens it with that password.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
# OpenSSL 3, first on PATH (macOS's own openssl is LibreSSL, which has no -legacy), as the runner's Homebrew one is.
o="$(brew --prefix openssl@3 2>/dev/null || true)/bin/openssl"; [ -x "$o" ] || o=$(command -v openssl)
ln -s "$o" "$T/bin/openssl"; PATH="$T/bin:$PATH"
check "OpenSSL 3 for these tests" "$(openssl version)" '^OpenSSL 3'
cat > "$T/bin/security" <<'STUB'
#!/usr/bin/env bash
case $1 in
  import) echo "import $4" >> "$RUNNER_TEMP/log"
    [ -n "$4" ] || { echo "security: SecKeychainItemImport: The user name or passphrase you entered is not correct." >&2; exit 1; }
    openssl pkcs12 -in "$2" -passin "pass:$4" -nokeys -out /dev/null 2>/dev/null ;;
  find-identity) echo '  1) 0123 "Apple Distribution: Example (TEAM123456)"' ;;
esac
STUB
chmod +x "$T/bin/security"
import=$(y 'w["jobs"]["ios"]["steps"].find { |s| s["name"] == "Import the distribution certificate" }["run"]')
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.pem" -out "$T/c.pem" -days 2 -subj "/CN=Apple Distribution: Example" 2>/dev/null
openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -passout pass: -out "$T/aes-empty.p12"
openssl pkcs12 -export -legacy -inkey "$T/k.pem" -in "$T/c.pem" -passout pass: -out "$T/legacy-empty.p12"
openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -passout pass:secret -out "$T/aes-secret.p12"
imp() { # <file> [password]
  rm -rf "$T/rt"; mkdir "$T/rt"
  env -i PATH="$PATH" HOME="$T" RUNNER_TEMP="$T/rt" CERTIFICATE_BASE64="$(base64 < "$1" | tr -d '\n')" \
    CERTIFICATE_PASSWORD="${2:-}" bash -e -o pipefail -c "$import" 2>&1; echo "rc=$?"; }
out=$(imp "$T/aes-secret.p12" secret)
check "import: a password: imported with it, once" "$(tail -1 <<<"$out"):$(cat "$T/rt/log")" '^rc=0:import secret$'
for f in aes-empty legacy-empty; do
  out=$(imp "$T/$f.p12")
  check "import: $f, no password: re-encoded and imported" "$(tail -1 <<<"$out"):$(wc -l < "$T/rt/log" | tr -d ' ')" '^rc=0:2$'
  check "... the empty password tried first" "$(head -1 "$T/rt/log")" '^import $'
  check "... no decrypted key left behind" "$(find "$T/rt" -name '*.pem' | wc -l | tr -d ' ')" '^0$'
done
out=$(imp "$T/aes-secret.p12")
check "import: a .p12 with a password, the secret unset: says to set it" "$out" '::error::The \.p12 does not open with an empty password: set APPLE_DIST_CERTIFICATE_PASSWORD'
check "... exit 1" "$(tail -1 <<<"$out")" '^rc=1$'

echo "$pass passed, $failed failed"; [ "$failed" = 0 ]
