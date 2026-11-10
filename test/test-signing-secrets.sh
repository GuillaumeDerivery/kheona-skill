#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The Android signing secrets' rename (CM_* -> ANDROID_*, a Codemagic leftover): the delivery takes both names, the new
# one wins, the lane gets both, and the callers pass both, until every repository holds the new ones.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); cd "$HERE" || exit 64
W=.github/workflows/kskill-deliver-flutter.yml
pass=0 failed=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1 (got: $2)"; fi; }
y() { ruby -ryaml -e 'w = YAML.load_file(ARGV[0]); puts eval(ARGV[1])' "$W" "$1"; }

declared=$(y '(w["on"] || w[true])["workflow_call"]["secrets"].keys.sort.join(" ")')
for n in KEYSTORE_PASSWORD KEY_ALIAS KEY_PASSWORD; do
  check "the delivery takes ANDROID_$n" "$declared" "(^| )ANDROID_$n( |$)"
  check "... and still CM_$n" "$declared" "(^| )CM_$n( |$)"
done
check "the callers pass every secret the delivery takes" \
  "$(jq -r '."kskill-deliver-flutter.yml".secrets | sort | join(" ")' .github/callers.json)" "^$declared$"

build=$(y 'w["jobs"]["android"]["steps"].find { |s| s["name"] == "Build and upload to Google Play" }["env"].map { |k, v| "#{k}=#{v}" }.join("\n")')
for n in KEYSTORE_PASSWORD KEY_ALIAS KEY_PASSWORD; do
  want="\\$\\{\\{ secrets\\.ANDROID_$n \\|\\| secrets\\.CM_$n \\}\\}"
  check "the lane gets ANDROID_$n, the new secret first" "$build" "(^|"$'\n'")ANDROID_$n=$want"
  check "... and CM_$n, the same value" "$build" "(^|"$'\n'")CM_$n=$want"
done
check "the keystore path under both names" "$(grep -c '_KEYSTORE_PATH=\$KEYSTORE_PATH' "$W")" '^2$'

# The secrets check, run as the step runs: the new name wins, an old one alone warns, both missing fail by new name.
script=$(y 'w["jobs"]["android"]["steps"].find { |s| s["name"] == "Check the signing secrets" }["run"]')
run() { env -i PATH="$PATH" REPO=owner/repo ANDROID_KEYSTORE_BASE64=k PLAY_STORE_JSON_KEY_BASE64=p "$@" bash -c "$script" 2>&1; echo "rc=$?"; }
out=$(run ANDROID_KEYSTORE_PASSWORD=a ANDROID_KEY_ALIAS=b ANDROID_KEY_PASSWORD=c)
check "the new names: passes, no warning" "$out" '^rc=0$'
out=$(run CM_KEYSTORE_PASSWORD=a CM_KEY_ALIAS=b CM_KEY_PASSWORD=c)
check "the old names alone: passes" "$out" 'rc=0$'
check "... with a deprecation warning each" "$(grep -c '::warning::CM_.* is deprecated' <<<"$out")" '^3$'
out=$(run ANDROID_KEYSTORE_PASSWORD=a ANDROID_KEY_ALIAS=b CM_KEY_PASSWORD=c)
check "a mix: passes, one warning" "$(grep -c '::warning::' <<<"$out"):$(tail -1 <<<"$out")" '^1:rc=0$'
out=$(run ANDROID_KEYSTORE_PASSWORD=a)
check "missing: fails by the new names" "$out" 'Missing repository secret\(s\): ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD\.'
check "... exit 1" "$(tail -1 <<<"$out")" '^rc=1$'

echo "$pass passed, $failed failed"; [ "$failed" = 0 ]
