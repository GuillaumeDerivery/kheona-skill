#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The delivery's secrets: Android ones start with ANDROID_, Apple ones with APPLE_. Their old names (before v2.9.0:
# CM_*, PLAY_STORE_*, IOS_DIST_*, ASC_*) are not read any more, nor passed to the lane. And the iOS .p12's password is
# optional: GitHub cannot store an empty secret, so a .p12 exported without one leaves it unset.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); cd "$HERE" || exit 64
W=.github/workflows/kskill-deliver-flutter.yml
pass=0 failed=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1 (got: $2)"; fi; }
y() { ruby -ryaml -e 'w = YAML.load_file(ARGV[0]); puts eval(ARGV[1])' "$W" "$1"; }
step() { y "w['jobs']['$1']['steps'].find { |s| s['name'] == '$2' }['env'].map { |k, v| \"#{k}=#{v}\" }.join(\"\\n\")"; }
OLD_RE='(CM|PLAY_STORE|IOS_DIST|ASC)_'

declared=$(y '(w["on"] || w[true])["workflow_call"]["secrets"].keys.sort.join(" ")')
check "the delivery takes the ANDROID_ and APPLE_ names, and the Sentry token" "$declared" \
  '^ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD ANDROID_PLAY_STORE_JSON_KEY_BASE64 APPLE_API_ISSUER_ID APPLE_API_KEY_BASE64 APPLE_API_KEY_ID APPLE_DIST_CERTIFICATE_P12_BASE64 APPLE_DIST_CERTIFICATE_PASSWORD SENTRY_AUTH_TOKEN$'
check "the callers pass every secret the delivery takes" \
  "$(jq -r '."kskill-deliver-flutter.yml".secrets | sort | join(" ")' .github/callers.json)" "^$declared$"
check "no old name left in the delivery" "$(grep -cE "(^|[^A-Z_])$OLD_RE" "$W")" '^0$'

# Each value from its one secret; the lane gets the new names only.
one() { echo "\\\$\\{\\{ secrets\\.$1 \\}\\}"; }
build=$(step android 'Build and upload to Google Play')
for n in ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
  check "the Android lane gets $n" "$build" "(^|"$'\n'")$n=$(one $n)("$'\n'"|$)"
done
build=$(step ios 'Build and upload to TestFlight')
for n in APPLE_API_KEY_ID APPLE_API_ISSUER_ID; do
  check "the iOS lane gets $n" "$build" "(^|"$'\n'")$n=$(one $n)("$'\n'"|$)"
done
check "the Play key decoded from its secret" "$(step android 'Decode the Play Console key')" \
  "^ANDROID_PLAY_STORE_JSON_KEY_BASE64=$(one ANDROID_PLAY_STORE_JSON_KEY_BASE64)$"
cert=$(step ios 'Import the distribution certificate')
check "the .p12 from its secret" "$cert" "CERTIFICATE_BASE64=$(one APPLE_DIST_CERTIFICATE_P12_BASE64)"
check "... its password too" "$cert" "CERTIFICATE_PASSWORD=$(one APPLE_DIST_CERTIFICATE_PASSWORD)"
check "the .p8 from its secret" "$(step ios 'Write the App Store Connect key')" \
  "^APPLE_API_KEY_BASE64=$(one APPLE_API_KEY_BASE64)$"
for v in ANDROID_KEYSTORE_PATH ANDROID_PLAY_STORE_JSON_KEY_PATH APPLE_API_KEY_FILEPATH; do
  check "the lane gets the file path $v" "$(grep -c "echo \"$v=\\\$[A-Z_]*PATH\" >> \"\\\$GITHUB_ENV\"" "$W")" '^1$'
done
check "... and no other" "$(grep -c '>> "$GITHUB_ENV"' <<<"$(grep -E 'echo "[A-Z_]*PATH=' "$W")")" '^3$'

# The secrets check, run as the step runs: an old name does not count, the missing ones fail by name.
script=$(y 'w["jobs"]["android"]["steps"].find { |s| s["name"] == "Check the signing secrets" }["run"]')
run() { env -i PATH="$PATH" REPO=owner/repo DRY_RUN=false ANDROID_KEYSTORE_BASE64=k "$@" bash -c "$script" 2>&1; echo "rc=$?"; }
out=$(run ANDROID_KEYSTORE_PASSWORD=a ANDROID_KEY_ALIAS=b ANDROID_KEY_PASSWORD=c ANDROID_PLAY_STORE_JSON_KEY_BASE64=p)
check "android, every secret: passes, nothing said" "$out" '^rc=0$'
out=$(run CM_KEYSTORE_PASSWORD=a CM_KEY_ALIAS=b CM_KEY_PASSWORD=c PLAY_STORE_JSON_KEY_BASE64=p)
check "android, the old names: fails by the new ones" "$out" 'Missing repository secret\(s\): ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD ANDROID_PLAY_STORE_JSON_KEY_BASE64\.'
check "... exit 1" "$(tail -1 <<<"$out")" '^rc=1$'
out=$(run ANDROID_KEYSTORE_PASSWORD=a)
check "android, missing: fails by name" "$out" 'Missing repository secret\(s\): ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD ANDROID_PLAY_STORE_JSON_KEY_BASE64\.'
check "... exit 1" "$(tail -1 <<<"$out")" '^rc=1$'
out=$(run DRY_RUN=true)
check "android, a dry run: says, passes" "$(grep -c '::notice::Dry run' <<<"$out"):$(tail -1 <<<"$out")" '^1:rc=0$'

# iOS: the same, and the .p12's password is optional, the .p12 itself is not.
check "the delivery takes APPLE_DIST_CERTIFICATE_PASSWORD, not required" \
  "$(y '(w["on"] || w[true])["workflow_call"]["secrets"]["APPLE_DIST_CERTIFICATE_PASSWORD"]["required"]')" '^false$'
script=$(y 'w["jobs"]["ios"]["steps"].find { |s| s["name"] == "Check the signing secrets" }["run"]')
ios() { env -i PATH="$PATH" REPO=owner/repo DRY_RUN=false "$@" bash -c "$script" 2>&1; echo "rc=$?"; }
NEW="APPLE_API_KEY_ID=i APPLE_API_ISSUER_ID=s APPLE_API_KEY_BASE64=k"
# shellcheck disable=SC2086 # why: one NAME=value per word
{
out=$(ios $NEW APPLE_DIST_CERTIFICATE_P12_BASE64=c APPLE_DIST_CERTIFICATE_PASSWORD=p)
check "ios, .p12 and password: passes, nothing said" "$out" '^rc=0$'
out=$(ios ASC_KEY_ID=i ASC_ISSUER_ID=s ASC_API_KEY_BASE64=k IOS_DIST_CERTIFICATE_P12_BASE64=c IOS_DIST_CERTIFICATE_PASSWORD=p)
check "ios, the old names: fails by the new ones" "$out" 'secret\(s\): APPLE_DIST_CERTIFICATE_P12_BASE64 APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_BASE64\. '
check "... exit 1" "$(tail -1 <<<"$out")" '^rc=1$'
out=$(ios $NEW APPLE_DIST_CERTIFICATE_P12_BASE64=c)
check "ios: .p12 without a password: passes" "$(tail -1 <<<"$out")" '^rc=0$'
check "... saying it imports with an empty password" "$out" '::notice::APPLE_DIST_CERTIFICATE_PASSWORD is not set: the \.p12 is imported with an empty password\.'
check "... no warning" "$(grep -c '::warning::' <<<"$out")" '^0$'
out=$(ios $NEW APPLE_DIST_CERTIFICATE_P12_BASE64=c IOS_DIST_CERTIFICATE_PASSWORD=p)
check "ios: the old password does not count: the notice" "$(grep -c '::notice::APPLE_DIST_CERTIFICATE_PASSWORD is not set' <<<"$out"):$(tail -1 <<<"$out")" '^1:rc=0$'
out=$(ios $NEW APPLE_DIST_CERTIFICATE_PASSWORD=p)
check "ios: no .p12: fails by name" "$out" 'Missing repository secret\(s\): APPLE_DIST_CERTIFICATE_P12_BASE64\.'
check "... no notice without a .p12" "$(grep -c '::notice::' <<<"$out"):$(tail -1 <<<"$out")" '^0:rc=1$'
out=$(ios)
check "ios: nothing: every name, never the password" "$out" 'secret\(s\): APPLE_DIST_CERTIFICATE_P12_BASE64 APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_BASE64\. '
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
