#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# .github/scripts/kskill-cd.sh: a fork's Actions variable KSKILL_CD laid over .kheona.json's workflows.cd.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); CD="$HERE/.github/scripts/kskill-cd.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failed=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1"; echo "     got:  $2"; echo "     want: $3"; fi; }
f="$T/.kheona.json"
echo '{"role":"template","workflows":{"ci":{"package":"x"},"cd":{"templateRepository":"o/t","platform":"linux/arm64","staging":false,"prod":false}}}' > "$f"

check "unset: the file as it is" "$(KSKILL_CD='' bash "$CD" "$f" | jq -c .)" "$(jq -c . "$f")"
check "blank: the file as it is" "$(KSKILL_CD='  ' bash "$CD" "$f" | jq -c .workflows.cd.staging)" 'false'
out=$(KSKILL_CD='{"platform":"linux/amd64","staging":{"cluster":"c","namespace":"n"}}' bash "$CD" "$f")
check "set keys replace the file's" "$(jq -c '[.workflows.cd.platform, .workflows.cd.staging]' <<<"$out")" '["linux/amd64",{"cluster":"c","namespace":"n"}]'
check "... the others stay" "$(jq -c '[.workflows.cd.prod, .workflows.cd.templateRepository, .workflows.ci.package, .role]' <<<"$out")" '[false,"o/t","x","template"]'
echo '{"role":"project"}' > "$T/bare.json"
check "no workflows in the file: created" "$(KSKILL_CD='{"prod":{"cluster":"c"}}' bash "$CD" "$T/bare.json" | jq -c .workflows)" '{"cd":{"prod":{"cluster":"c"}}}'
err=$(KSKILL_CD='[1,2]' bash "$CD" "$f" 2>&1 >/dev/null); rc=$?
check "not an object: refused, naming the variable, never its value" "$rc:$(grep -c 'KSKILL_CD is not a JSON object' <<<"$err"):$(grep -c '\[1,2\]' <<<"$err")" '1:1:0'
err=$(KSKILL_CD='{"a":' bash "$CD" "$f" 2>&1 >/dev/null); check "invalid JSON: refused" "$?" '1'
check "missing file: refused" "$(bash "$CD" "$T/none.json" 2>/dev/null; echo $?)" '1'
echo "$pass passed, $failed failed"; [ "$failed" = 0 ]
