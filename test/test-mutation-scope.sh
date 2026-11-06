#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline tests for .github/scripts/kskill-mutation-scope.mjs: which files a mutation run mutates (only those
# changed since the last green run's commit), when it falls back to the full scope, and when it skips, against a
# fixture git repository and a fake gh.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/.github/scripts/kskill-mutation-scope.mjs"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
check() { # check <name> <output> <grep -E pattern> [absent]
  if { [ "${4:-}" = absent ] && ! grep -qE "$3" <<<"$2"; } || { [ "${4:-}" != absent ] && grep -qE "$3" <<<"$2"; }; then
    pass=$((pass+1)); echo "ok   $1"
  else failn=$((failn+1)); echo "FAIL $1 (pattern $3${4:+, $4})"; printf '     %s\n' "${2//$'\n'/$'\n'     }"; fi
}
R="$T/repo"; mkdir -p "$R/src/core" "$R/tests" "$R/.github/config"
commit() { git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm "$1" --allow-empty; git -C "$R" rev-parse HEAD; }
git -C "$R" init -q
echo 'export default { testRunner: "command" };' > "$R/.github/config/kskill-stryker.mjs"
cat > "$R/stryker.config.mjs" <<'CFG'
import base from './.github/config/kskill-stryker.mjs';
export default { ...base, mutate: ['src/**/*.ts', '!src/**/*.d.ts'] };
CFG
echo a > "$R/src/a.ts"; echo b > "$R/src/core/b.ts"; echo t > "$R/tests/a.ts"
BASE=$(commit one)

# fake gh: the artifacts listing answers $FAKE/artifacts.json; $FAKE/down makes every call fail.
mkdir -p "$T/bin" "$T/fake"; FAKE="$T/fake"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
jqx=.; path=""; args=("$@")
for ((i = 1; i < ${#args[@]}; i++)); do case "${args[i]}" in --jq) jqx=${args[i+1]}; i=$((i+1)) ;; -*) ;; *) [ -n "$path" ] || path=${args[i]} ;; esac; done
[ -f "$FAKE/down" ] && { echo "gh: HTTP 502" >&2; exit 1; }
case "$path" in */actions/artifacts\?name=mutation-base*) ;; *) echo "fake gh: unexpected $*" >&2; exit 1 ;; esac
[ -f "$FAKE/artifacts.json" ] || { echo '{"artifacts":[]}' | jq -r "$jqx"; exit 0; }
jq -r "$jqx" "$FAKE/artifacts.json"
GH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" FAKE GH_REPO=o/r GITHUB_REF_NAME=main
scope() { ( cd "$R" && rm -f "$T/out" && GITHUB_OUTPUT="$T/out" GITHUB_STEP_SUMMARY=/dev/null node "$SCRIPT" --config stryker.config.mjs "$@" >/dev/null 2>&1; cat "$T/out" ); }
artifact() { printf '{"artifacts":[%s]}' "$1" > "$FAKE/artifacts.json"; }
art() { echo "{\"expired\":${3:-false},\"workflow_run\":{\"head_sha\":\"$1\",\"head_branch\":\"${2:-main}\"}}"; }

out=$(scope)
check "no earlier green run: the full scope"            "$out" '^mode=full$'
check "the full scope passes no --mutate list"          "$out" '^mutate=$'
out=$(scope --base "$(git -C "$R" rev-parse HEAD)")
check "nothing changed since the base: skipped"         "$out" '^mode=none$'

echo a2 > "$R/src/a.ts"; echo t2 > "$R/tests/a.ts"; echo d > "$R/src/x.d.ts"; echo n > "$R/src/core/new.ts"; echo r > "$R/README.md"
commit two > /dev/null
artifact "$(art "$BASE")"
out=$(scope)
check "the base comes from the mutation-base artifact"  "$out" "^base=$BASE$"
check "changed files in scope are mutated"              "$out" '^mode=changed$'
check "the modified and the added source file, sorted"  "$out" '^mutate=src/a.ts,src/core/new.ts$'
check "a test, a declaration file, a README: not mutated" "$out" 'tests/a.ts|x\.d\.ts|README' absent
artifact "$(art 1111111111111111111111111111111111111111 main true),$(art "$BASE" other),$(art "$BASE")"
out=$(scope)
check "an expired or another branch's artifact is passed over" "$out" "^base=$BASE$"
artifact "$(art "$BASE" other)"
check "only another branch's: the full scope"           "$(scope)" '^mode=full$'
touch "$FAKE/down"
check "an API error: the full scope"                    "$(scope)" '^mode=full$'
rm "$FAKE/down"
check "a base outside the history: the full scope"      "$(scope --base 2222222222222222222222222222222222222222)" '^mode=full$'
check "a base that is not a sha: the full scope"        "$(scope --base main)" '^mode=full$'
TWO=$(git -C "$R" rev-parse HEAD)
git -C "$R" rm -q src/core/b.ts; git -C "$R" mv src/a.ts src/c.ts; commit three > /dev/null
out=$(scope --base "$TWO")
check "a deleted file is not mutated, a renamed one is" "$out" '^mutate=src/c.ts$'
THREE=$(git -C "$R" rev-parse HEAD)
echo "// changed" >> "$R/stryker.config.mjs"; commit four > /dev/null
check "the Stryker config changed: the full scope"      "$(scope --base "$THREE")" '^mode=full$'
FOUR=$(git -C "$R" rev-parse HEAD)
echo "// changed" >> "$R/.github/config/kskill-stryker.mjs"; commit five > /dev/null
check "the shared options changed: the full scope"      "$(scope --base "$FOUR")" '^mode=full$'
FIVE=$(git -C "$R" rev-parse HEAD)
echo x > "$R/src/with space.ts"; commit six > /dev/null
check "a file name with a space: the full scope"        "$(scope --base "$FIVE")" '^mode=full$'
echo '{"mutate":["src/**/*.ts"]}' > "$R/stryker.config.json"; rm "$R/src/with space.ts"; commit seven > /dev/null
SEVEN=$(git -C "$R" rev-parse HEAD); echo z >> "$R/src/c.ts"; commit eight > /dev/null
out=$( cd "$R" && GITHUB_OUTPUT="$T/out2" node "$SCRIPT" --config stryker.config.json --base "$SEVEN" >/dev/null 2>&1; cat "$T/out2" )
check "a JSON config's mutate is read too"              "$out" '^mutate=src/c.ts$'
echo 'export default { mutate: [] };' > "$R/empty.config.mjs"
check "an empty mutate list: the full scope (the config check reports it)" "$( cd "$R" && GITHUB_OUTPUT="$T/out3" node "$SCRIPT" --config empty.config.mjs --base "$SEVEN" >/dev/null 2>&1; cat "$T/out3" )" '^mode=full$'
out=$( cd "$R" && node "$SCRIPT" --config missing.mjs 2>&1; echo "exit=$?" )
check "a missing config fails"                          "$out" 'exit=1'

echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
