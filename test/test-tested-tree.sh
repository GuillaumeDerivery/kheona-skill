#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline tests for .github/scripts/kskill-tested-tree.sh: when a push reuses a green PR run of its tree, and
# every case where the gate must run in full, against a fake gh.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/.github/scripts/kskill-tested-tree.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
check() { # check <name> <output> <grep -E pattern> [absent]
  if { [ "${4:-}" = absent ] && ! grep -qE "$3" <<<"$2"; } || { [ "${4:-}" != absent ] && grep -qE "$3" <<<"$2"; }; then
    pass=$((pass+1)); echo "ok   $1"
  else failn=$((failn+1)); echo "FAIL $1 (pattern $3${4:+, $4})"; printf '     %s\n' "${2//$'\n'/$'\n'     }"; fi
}
# A repository with one commit: its tree is what a push tested.
R="$T/repo"; mkdir -p "$R"; git -C "$R" init -q; echo a > "$R/a"; git -C "$R" add a
git -C "$R" -c user.name=t -c user.email=t@t commit -qm one; TREE=$(git -C "$R" rev-parse 'HEAD^{tree}')

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
jqx=.; path=""; args=("$@")
for ((i = 1; i < ${#args[@]}; i++)); do case "${args[i]}" in --jq) jqx=${args[i+1]}; i=$((i+1)) ;; -*) ;; *) [ -n "$path" ] || path=${args[i]} ;; esac; done
[ -f "$FAKE/down" ] && { echo "gh: HTTP 502" >&2; exit 1; }
case "$path" in
  */actions/artifacts\?name=*) f=artifacts.json ;;
  */actions/runs/*/jobs*) id=${path#*/runs/}; f=jobs-${id%%/*}.json ;;
  */actions/runs/*) f=run-${path##*/}.json ;;
  *) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
[ -f "$FAKE/$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
jq -r "$jqx" "$FAKE/$f"
GH
chmod +x "$T/bin/gh"
FAKE="$T/fake"
reset() { rm -rf "$FAKE"; mkdir -p "$FAKE"; }
put() { printf '%s' "$2" > "$FAKE/$1"; }
artifact() { put artifacts.json "{\"artifacts\":[$1]}"; }
art() { echo "{\"name\":\"kskill-tested-tree-$TREE\",\"expired\":${2:-false},\"workflow_run\":{\"id\":$1}}"; }
run() { # run <id> [path] [event] [repo]
  put "run-$1.json" "{\"event\":\"${3:-pull_request}\",\"path\":\"${2:-.github/workflows/kskill-pr.yml}\",\"head_repository\":{\"full_name\":\"${4:-o/r}\"},\"html_url\":\"https://run/$1\",\"pull_requests\":[{\"number\":7}]}"
}
jobs() { put "jobs-$1.json" "{\"jobs\":[$2]}"; }
job() { echo "{\"name\":\"$1\",\"status\":\"${2:-completed}\",\"conclusion\":${3:-\"success\"}}"; }
GREEN="$(job 'CI / Read the configuration'),$(job 'CI / Check, build and test'),$(job 'CI / Build the Docker image' completed '"skipped"'),$(job 'Merge if eligible' in_progress null)"
find_() { (cd "$R" && : > "$T/out" && env PATH="$T/bin:$PATH" FAKE="$FAKE" GH_TOKEN=x GH_REPO=o/r EVENT_NAME=push \
  GITHUB_REF=refs/heads/main DEFAULT_BRANCH=main GITHUB_OUTPUT="$T/out" GITHUB_STEP_SUMMARY=/dev/null "$@" bash "$SCRIPT" find 2>&1; cat "$T/out"); }

out=$(cd "$R" && : > "$T/out" && RUNNER_TEMP="$T" GITHUB_OUTPUT="$T/out" bash "$SCRIPT" record >/dev/null && cat "$T/out" "$T/kskill-tested-tree.txt")
check "record: the checked-out tree"                      "$out" "^tree=$TREE$"
check "record: a file naming it, to upload"               "$out" "^tree $TREE$"

reset; artifact "$(art 11)"; run 11; jobs 11 "$GREEN"
out=$(find_)
check "a green PR run of this tree: reused"               "$out" '^reused=true$'
check "... naming the run and the PR"                     "$out" '^run=https://run/11$'
check "... the PR"                                        "$out" '^pr=7$'
check "... a merge job still running does not matter"     "$out" 'the rest of this gate is skipped'
check "a pull_request run never reuses"                   "$(find_ EVENT_NAME=pull_request)" '^reused=false$'
check "a dispatch never reuses"                           "$(find_ EVENT_NAME=workflow_dispatch)" '^reused=false$'
check "prod never reuses: shipping runs the full gate"    "$(find_ GITHUB_REF=refs/heads/prod)" '^reused=false$'
check "no default branch known: full"                     "$(find_ DEFAULT_BRANCH=)" '^reused=false$'
reset; artifact ""
check "no artifact for this tree: full"                   "$(find_)" 'no Kheona Skill · PR run tested tree'
reset; artifact "$(art 11 true)"; run 11; jobs 11 "$GREEN"
check "an expired artifact: full"                         "$(find_)" '^reused=false$'
reset; artifact "$(art 11)"; run 11 .github/workflows/other.yml; jobs 11 "$GREEN"
check "an artifact from another workflow: full"           "$(find_)" '^reused=false$'
reset; artifact "$(art 11)"; run 11 .github/workflows/kskill-pr.yml pull_request someone/fork; jobs 11 "$GREEN"
check "a run from another repository: full"               "$(find_)" '^reused=false$'
reset; artifact "$(art 11)"; run 11 .github/workflows/kskill-pr.yml push; jobs 11 "$GREEN"
check "a run that was not a pull_request: full"           "$(find_)" '^reused=false$'
reset; artifact "$(art 11)"; run 11; jobs 11 "$(job 'CI / Read the configuration'),$(job 'CI / Check, build and test' completed '"failure"')"
check "a CI job failed: full"                             "$(find_)" '^reused=false$'
reset; artifact "$(art 11)"; run 11; jobs 11 "$(job 'CI / Read the configuration'),$(job 'CI / Check, build and test' in_progress null)"
check "CI still running: full"                            "$(find_)" '^reused=false$'
reset; artifact "$(art 11)"; run 11; jobs 11 "$(job 'CI / Read the configuration' completed '"skipped"')"
check "CI all skipped (nothing ran): full"                "$(find_)" '^reused=false$'
reset; artifact "$(art 11)"; run 11; jobs 11 "$(job 'Merge if eligible')"
check "no CI job in the run: full"                        "$(find_)" '^reused=false$'
reset; artifact "$(art 11)"; run 11; jobs 11 "$(job 'CI / Check' completed '"cancelled"')"
check "a cancelled CI: full"                              "$(find_)" '^reused=false$'
reset; artifact "$(art 11),$(art 12)"; run 11; jobs 11 "$(job 'CI / Check' completed '"failure"')"; run 12; jobs 12 "$GREEN"
check "a failed run and a green one: the green one"       "$(find_)" '^run=https://run/12$'
reset; artifact "$(art 11)"; run 11; jobs 11 "$GREEN"; touch "$FAKE/down"
check "GitHub unreachable: full"                          "$(find_)" '^reused=false$'

echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
