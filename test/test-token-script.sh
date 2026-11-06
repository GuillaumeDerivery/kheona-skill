#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# kskill-token.sh against a fake curl: the broker's own refusal, and a refusal from something in front of it.
set -uo pipefail
unset GITHUB_ACTIONS
HERE=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failed=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1 (got: $2)"; fi; }
mkdir "$T/bin"
cat > "$T/bin/curl" <<'C'
#!/usr/bin/env bash
case "$*" in
  *audience=*) echo '{"value":"oidc"}' ;;
  *) printf '%s\n%s' "$FAKE_BODY" "$FAKE_STATUS" ;;
esac
C
chmod +x "$T/bin/curl"
run() {
  FAKE_BODY=$1 FAKE_STATUS=$2 PATH="$T/bin:$PATH" GITHUB_OUTPUT="$T/out" KSKILL_TOKEN_BROKER_URL=https://broker.example.com \
    ACTIONS_ID_TOKEN_REQUEST_URL='https://oidc.example.com/?a=1' ACTIONS_ID_TOKEN_REQUEST_TOKEN=t bash "$HERE/.github/scripts/kskill-token.sh" 2>&1
}
out=$(run '{"token":"abc"}' 200); rc=$?
check "a token: exit 0" "$rc" '^0$'
check "... written to the step's output" "$(cat "$T/out")" '^token=abc$'
out=$(run '{"error":"owner not allowed"}' 403); rc=$?
check "the broker's refusal: exit 1" "$rc" '^1$'
check "... with its reason" "$out" 'HTTP 403 owner not allowed'
out=$(run '<!DOCTYPE html><title>Just a moment...</title>' 403); rc=$?
check "a page in front of the broker: exit 1" "$rc" '^1$'
check "... says so" "$out" "not the broker's answer"
echo "$pass passed, $failed failed"; [ "$failed" = 0 ]
