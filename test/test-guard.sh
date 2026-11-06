#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The guard, on a throwaway repository: terms found by place, the term itself never printed.
set -uo pipefail
unset GITHUB_ACTIONS
HERE=$(cd "$(dirname "$0")/.." && pwd); G="$HERE/.github/scripts/kskill-guard.mjs"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failed=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1 (got: $2)"; fi; }
printf '# a comment\nSecretCorp\n\n' > "$T/list"
git -C "$T" init -q r; R=$T/r; git -C "$R" config user.email a@example.com; git -C "$R" config user.name a
echo clean > "$R/a.txt"; git -C "$R" add -A; git -C "$R" commit -qm first
out=$(KSKILL_GUARD_LIST=$T/list node "$G" --repo "$R" 2>&1); rc=$?
check "clean: exit 0" "$rc $out" '^0 guard: 1 term\(s\), 0 hit'
out=$(node "$G" --repo "$R" 2>&1); rc=$?
check "no list: refuses, never passes" "$rc" '^64$'
echo 'ask secretcorp here' > "$R/a.txt"; git -C "$R" add -A
out=$(KSKILL_GUARD_LIST=$T/list node "$G" --repo "$R" 2>&1); rc=$?
check "a term in a file, any case: exit 1, file and line" "$rc $out" '^1 a\.txt:1: 1 forbidden'
check "... the term is never printed" "$( [[ $out == *ecret* ]] && echo leaked || echo clean )" '^clean$'
git -C "$R" commit -qm 'second' ; echo clean > "$R/a.txt"; git -C "$R" add -A; git -C "$R" commit -qm 'mention SecretCorp'
out=$(KSKILL_GUARD_LIST=$T/list node "$G" --repo "$R" --commits HEAD~1..HEAD 2>&1); rc=$?
check "a term in a commit message" "$rc $out" '^1 commit [0-9a-f]{12}:'
printf 'secretcorp/kheona-skill\n' > "$R/a.txt"; git -C "$R" add -A
out=$(KSKILL_GUARD_LIST=$T/list node "$G" --repo "$R" --self SecretCorp/kheona-skill 2>&1); rc=$?
check "--self: the repository may name itself" "$rc" '^0$'
printf 'secretcorp/other\n' > "$R/a.txt"; git -C "$R" add -A
out=$(KSKILL_GUARD_LIST=$T/list node "$G" --repo "$R" --self SecretCorp/kheona-skill 2>&1); rc=$?
check "... its owner alone stays forbidden" "$rc" '^1$'
printf 'id 1234567%s\n' 89012 > "$R/a.txt"; git -C "$R" add -A
out=$(KSKILL_GUARD_LIST=$T/list node "$G" --repo "$R" 2>&1); rc=$?
check "an account id" "$rc $out" '^1 a\.txt:1: an account id'
printf 'id 111122223333\n' > "$R/a.txt"; git -C "$R" add -A
out=$(KSKILL_GUARD_LIST=$T/list node "$G" --repo "$R" 2>&1); rc=$?
check "... the placeholder passes" "$rc" '^0$'
printf 'Terms: SecretCorp\n' > "$T/pr"
out=$(KSKILL_GUARD_LIST=$T/list node "$G" --repo "$R" --no-files --text-file "$T/pr" 2>&1); rc=$?
check "the text of a PR" "$rc" '^1$'
out=$(GITHUB_ACTIONS=true KSKILL_GUARD_LIST=$T/list node "$G" --repo "$R" --no-files --text-file "$T/pr" 2>&1); rc=$?
check "on GitHub, a hit is an error annotation" "$rc $out" '^1 ::error::'
echo "$pass passed, $failed failed"; [ "$failed" = 0 ]
