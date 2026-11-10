#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline test of scripts/kskill-renovate-plan.sh: GitHub's API is a stub `curl` on PATH. The configuration it writes
# must carry the App's login and commit identity (Renovate finds its Dependency Dashboard by that login).
set -uo pipefail
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "0 passed, 0 failed (skipped: the script needs bash 4+)"; exit 0; }
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else failn=$((failn+1)); echo "FAIL $1 (expected \"$3\", got \"$2\")"; fi; }
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do u=$a; done
case "$u" in
  */users/example-app%5Bbot%5D) echo '{"id": 4242}' ;;
  */contents/package.json) echo '{"dependencies": {"left-pad": "1.0.0"}}' ;;
  */contents/.gitmodules) exit 22 ;;
  *) exit 22 ;;
esac
STUB
chmod +x "$T/bin/curl"
echo '{"owner": "t1", "other": "t2"}' > "$T/tokens.json"
out=$(PATH="$T/bin:$PATH" KSKILL_BOT='example-app[bot]' KSKILL_LIB_REPO=owner/lib KSKILL_APP_TOKENS="$T/tokens.json" \
  REPOSITORIES='owner/repo other/repo' DRY_RUN=full bash "$HERE/scripts/kskill-renovate-plan.sh" "$T/out" 2>&1); rc=$?
check "exits 0" "$rc" 0
check "owners" "$(cat "$T/out/owners.json" 2>/dev/null)" '["other","owner"]'
check "username" "$(jq -r .username "$T/out/renovate-owner.json" 2>/dev/null)" 'example-app[bot]'
check "gitAuthor" "$(jq -r .gitAuthor "$T/out/renovate-owner.json" 2>/dev/null)" 'example-app[bot] <4242+example-app[bot]@users.noreply.github.com>'
check "npm may fetch a direct git dependency (the shared configs), nothing deeper" "$(jq -c "[.npmrc, .npmrcMerge]" "$T/out/renovate-owner.json" 2>/dev/null)" '["allow-git=root\n",true]'
check "repositories" "$(jq -c .repositories "$T/out/renovate-owner.json" 2>/dev/null)" '["owner/repo"]'
check "dry run" "$(jq -r .dryRun "$T/out/renovate-owner.json" 2>/dev/null)" full
PATH="$T/bin:$PATH" KSKILL_LIB_REPO=owner/lib KSKILL_APP_TOKENS="$T/tokens.json" REPOSITORIES=owner/repo \
  bash "$HERE/scripts/kskill-renovate-plan.sh" "$T/out2" >/dev/null 2>&1; rc=$?
check "KSKILL_BOT required" "$([ $rc -ne 0 ] && echo refused)" refused
[ $failn -eq 0 ] || echo "$out"
echo "$pass passed, $failn failed"; [ $failn -eq 0 ]
