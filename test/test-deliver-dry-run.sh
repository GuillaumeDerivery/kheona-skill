#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The delivery's dry run (the self-test): each lane runs up to signing, then nothing that builds, signs or uploads.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); cd "$HERE" || exit 64
W=.github/workflows/kskill-deliver-flutter.yml
pass=0 failed=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1 (got: $2)"; fi; }
y() { ruby -ryaml -e 'w = YAML.load_file(ARGV[0]); puts eval(ARGV[1])' "${2:-$W}" "$1"; }

check "the self-test runs the delivery as a dry run" \
  "$(y 'w["jobs"].values.map { |j| [j["uses"], j.dig("with", "dry_run")].join(" ") }' .github/workflows/self-test.yml)" \
  'kskill-deliver-flutter\.yml true'
check "the gate is skipped on a dry run" "$(y 'w["jobs"]["ci"]["if"]')" '!inputs\.dry_run'

for lane in android ios; do
  check "$lane: runs on a dry run's skipped gate" "$(y "w['jobs']['$lane']['if']")" \
    "!cancelled\(\).*needs\.ci\.result == 'success' \|\| \(inputs\.dry_run && needs\.ci\.result == 'skipped'\)"
  # every step, as "<name>\t<if>", in order
  steps=$(y "w['jobs']['$lane']['steps'].map { |s| \"#{s['name'] || s['uses']}\t#{s['if']}\" }.join(\"\n\")")
  stop=$(grep -n $'^Stop here on a dry run\tinputs.dry_run$' <<<"$steps" | cut -d: -f1)
  check "$lane: one step stops a dry run" "${stop:-none}" '^[0-9]+$'
  before=$(head -n $((${stop:-1} - 1)) <<<"$steps"); after=$(tail -n +$((${stop:-0} + 1)) <<<"$steps")
  check "$lane: the build number and name come before it" "$(cut -f1 <<<"$before" | tr '\n' '|')" 'Derive the build number\|Derive the build name\|$'
  check "$lane: the secrets check comes before it" "$(cut -f1 <<<"$before")" 'Check the signing secrets'
  check "$lane: nothing before it signs, builds or sets a toolchain up" \
    "$(cut -f1 <<<"$before" | grep -ciE 'keystore|certificate|key$|fastlane|flutter|java|ruby|build and upload')" '^0$'
  unguarded=$(awk -F'\t' '$2 !~ /!inputs\.dry_run/ && $2 !~ /^failure\(\)$/ { print $1 }' <<<"$after")
  check "$lane: every step after it is off on a dry run" "${unguarded:-none}" '^none$'
done
check "ios: Xcode is not selected on a dry run (Linux)" \
  "$(y 'w["jobs"]["ios"]["steps"].find { |s| s["name"] == "Select Xcode" }["if"]')" '!inputs\.dry_run'
check "ios: a dry run runs on Linux, a delivery on macOS" "$(y 'w["jobs"]["ios"]["runs-on"]')" \
  "inputs\.dry_run && 'ubuntu-[0-9.]+' \|\| 'macos-[0-9]+'"

# The secrets check, run as the step runs: a dry run reports, a delivery fails.
for lane in android ios; do
  script=$(y "w['jobs']['$lane']['steps'].find { |s| s['name'] == 'Check the signing secrets' }['run']")
  out=$(env -i PATH="$PATH" REPO=owner/repo DRY_RUN=true bash -c "$script" 2>&1; echo "rc=$?")
  check "$lane: no secrets on a dry run: a notice, exit 0" "$out" '::notice::Dry run: .*missing.*rc=0$'
  out=$(env -i PATH="$PATH" REPO=owner/repo DRY_RUN=false bash -c "$script" 2>&1; echo "rc=$?")
  check "$lane: no secrets on a delivery: an error, exit 1" "$out" '::error::Missing repository secret.*rc=1$'
done

echo "$pass passed, $failed failed"; [ "$failed" = 0 ]
