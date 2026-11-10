#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline tests for .github/scripts/kskill-release-check.sh: the environment comes from the ref, and production goes
# ahead only for a person's merged release PR, staging passed, or a person's rollback to a published release.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/.github/scripts/kskill-release-check.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
check() { # check <name> <output> <grep -E pattern>
  if grep -qE -- "$3" <<<"$2"; then pass=$((pass+1)); echo "ok   $1"
  else failn=$((failn+1)); echo "FAIL $1 (pattern $3)"; printf '     %s\n' "${2//$'\n'/$'\n'     }"; fi
}
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
jqx=.; path=""; args=("$@")
for ((i = 1; i < ${#args[@]}; i++)); do case "${args[i]}" in --jq) jqx=${args[i+1]}; i=$((i+1)) ;; -*) ;; *) [ -n "$path" ] || path=${args[i]} ;; esac; done
case "$path" in
  */compare/*) f=compare.json ;;
  */tags\?*) f=tags.json ;;
  */commits/*/pulls) f=pulls.json ;;
  */commits/*) f=commit.json ;;
  */pulls/*) f=pr.json ;;
  */actions/runs\?*) f=runs.json; [ -f "$FAKE/runs.next.json" ] && [ -f "$FAKE/runs.json" ] && { jq -r "$jqx" "$FAKE/runs.json"; mv "$FAKE/runs.next.json" "$FAKE/runs.json"; exit 0; } ;;
  */releases/tags/*) f=release.json ;;
  repos/o/r) f=repo.json ;;
  */collaborators/*/permission) f="perm-$(cut -d/ -f5 <<<"$path").json" ;;
  *) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
[ -f "$FAKE/$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
jq -r "$jqx" "$FAKE/$f"
GH
chmod +x "$T/bin/gh"
FAKE="$T/fake"; S=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
put() { printf '%s' "$2" > "$FAKE/$1"; }
good() { # a release PR merged by a person, staging green on the parent
  rm -rf "$FAKE"; mkdir -p "$FAKE"
  put compare.json '{"status":"identical"}'
  put tags.json '[{"name":"v1.9.0"},{"name":"v1.10.0"},{"name":"latest"}]'
  put pulls.json "[{\"number\":5,\"merged_at\":\"x\",\"merge_commit_sha\":\"$S\",\"base\":{\"ref\":\"main\"}}]"
  put pr.json '{"head":{"ref":"release-please--branches--main","repo":{"full_name":"o/r"}},"merged_by":{"login":"ann","type":"User"}}'
  put commit.json '{"parents":[{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}'
  put runs.json '{"workflow_runs":[{"path":".github/workflows/kskill-main.yml","head_branch":"main","status":"completed","conclusion":"success","html_url":"https://run/1"}]}'
  put release.json '{"draft":false}'
  put perm-ann.json '{"role_name":"write"}'
  put perm-bob.json '{"role_name":"read"}'
  put repo.json '{"fork":false}'
}
run() { # run <event> <ref> [actor]
  : > "$T/out"
  (PATH="$T/bin:$PATH" FAKE="$FAKE" GH_REPO=o/r EVENT_NAME=$1 GITHUB_REF=$2 GITHUB_SHA=$S DEFAULT_BRANCH=main \
    ACTOR=${3:-ann} DRY_RUN=${DRY_RUN:-false} GITHUB_OUTPUT="$T/out" bash "$SCRIPT" 2>&1; echo "rc=$?")
  cat "$T/out"
}

good
out=$(run push refs/heads/main);                check "main: staging"                              "$out" '^environment=staging$'
out=$(run workflow_dispatch refs/heads/main);   check "dispatch on main: staging"                  "$out" '^environment=staging$'
out=$(run push refs/heads/feature);             check "another branch: refused"                    "$out" 'deploys nothing'
out=$(run pull_request refs/pull/1/merge);      check "a PR without dry run: refused"              "$out" '^rc=1$'
out=$(DRY_RUN=true run pull_request refs/pull/1/merge); check "a PR dry run: staging"             "$out" '^environment=staging$'
out=$(run push refs/tags/v1.10.0);              check "a person's release: prod"                   "$out" '^environment=prod$'
check "... with its version"                                                                        "$out" '^version=v1.10.0$'
check "... and the commit staging tested"                                                           "$out" '^tested=b{40}$'
out=$(run push refs/tags/v1.10.0-rc1);          check "not vX.Y.Z: refused"                        "$out" 'is not a version'
out=$(run push refs/tags/release);              check "any other tag: refused"                     "$out" '^rc=1$'
put compare.json '{"status":"diverged"}'
out=$(run push refs/tags/v1.10.0);              check "a tag off main: refused"                    "$out" 'is not on main'
good; put tags.json '[{"name":"v1.10.0"},{"name":"v1.11.0"}]'
out=$(run push refs/tags/v1.10.0);              check "a pushed tag older than the newest: refused" "$out" 'not the newest version'
good; put pulls.json '[]'
out=$(run push refs/tags/v1.10.0);              check "a commit pushed without a PR: refused"      "$out" 'is not the merge of a pull request'
good; put pr.json '{"head":{"ref":"feature","repo":{"full_name":"o/r"}},"merged_by":{"login":"ann","type":"User"}}'
out=$(run push refs/tags/v1.10.0);              check "any other PR's merge: refused"              "$out" "is not this repository's release PR"
good; put pr.json '{"head":{"ref":"release-please--branches--main","repo":{"full_name":"x/fork"}},"merged_by":{"login":"ann","type":"User"}}'
out=$(run push refs/tags/v1.10.0);              check "a fork's release-please branch: refused"    "$out" "release PR"
good; put pr.json '{"head":{"ref":"release-please--branches--main","repo":{"full_name":"o/r"}},"merged_by":{"login":"app[bot]","type":"Bot"}}'
out=$(run push refs/tags/v1.10.0);              check "merged by a bot: refused"                   "$out" 'only a person releases'
good; put pr.json '{"head":{"ref":"release-please--branches--main","repo":{"full_name":"o/r"}},"merged_by":{"login":"bob","type":"User"}}'
out=$(run push refs/tags/v1.10.0);              check "merged by a reader: refused"                "$out" "has 'read' access"
good; put runs.json '{"workflow_runs":[{"path":".github/workflows/kskill-main.yml","head_branch":"main","status":"completed","conclusion":"failure","html_url":"x"}]}'
out=$(run push refs/tags/v1.10.0);              check "staging failed on the parent: refused"      "$out" 'production waits for staging'
good; put runs.json '{"workflow_runs":[{"path":".github/workflows/kskill-main.yml","head_branch":"main","status":"in_progress","conclusion":null,"html_url":"x"}]}'
put runs.next.json '{"workflow_runs":[{"path":".github/workflows/kskill-main.yml","head_branch":"main","status":"completed","conclusion":"success","html_url":"https://run/2"}]}'
out=$(KSKILL_MAIN_WAIT_INTERVAL=0 run push refs/tags/v1.10.0); check "staging still running on the parent: waits, then prod" "$out" '^environment=prod$'
check "... saying it waited"                                                                        "$out" 'still runs on bbbbbbb.*waiting'
good; put runs.json '{"workflow_runs":[{"path":".github/workflows/kskill-main.yml","head_branch":"main","status":"in_progress","conclusion":null,"html_url":"x"}]}'
out=$(KSKILL_MAIN_WAIT_SECONDS=0 run push refs/tags/v1.10.0); check "staging still running past the wait: refused" "$out" 'still runs on bbbbbbb.*after 0 min'
good; put runs.json '{"workflow_runs":[{"path":".github/workflows/kskill-main.yml","head_branch":"main","status":"in_progress","conclusion":null,"html_url":"x"}]}'
put runs.next.json '{"workflow_runs":[{"path":".github/workflows/kskill-main.yml","head_branch":"main","status":"completed","conclusion":"failure","html_url":"x"}]}'
out=$(KSKILL_MAIN_WAIT_INTERVAL=0 run push refs/tags/v1.10.0); check "staging fails while waited for: refused" "$out" 'production waits for staging'
good; rm "$FAKE/runs.json"
out=$(run push refs/tags/v1.10.0);              check "an API error: refused"                      "$out" 'does not deploy when unsure'
good
out=$(run workflow_dispatch refs/tags/v1.9.0 ann); check "a person's rollback: prod"               "$out" '^version=v1.9.0$'
check "... no tested commit (nothing to promote)"                                                   "$(grep -c '^tested=' <<<"$out")" '^0$'
out=$(run workflow_dispatch refs/tags/v1.9.0 bob); check "a reader's rollback: refused"            "$out" "has 'read' access"
out=$(run workflow_dispatch refs/tags/v1.9.0 'x[bot]'); check "a bot's rollback: refused"          "$out" 'is not a person'
put release.json '{"draft":true}'
out=$(run workflow_dispatch refs/tags/v1.9.0 ann); check "a rollback to a draft: refused"          "$out" 'not a published release'
rm "$FAKE/release.json"
out=$(run workflow_dispatch refs/tags/v1.9.0 ann); check "a rollback to a tag with no release: refused" "$out" '^rc=1$'
check "... and no environment written"                                                              "$(cat "$T/out")" '^$'
good; put repo.json '{"fork":true}'; put pulls.json '[]'; rm "$FAKE/runs.json"
out=$(run push refs/tags/v1.10.0 ann);          check "a fork's published release: prod"           "$out" '^version=v1.10.0$'
out=$(run push refs/tags/v1.10.0 bob);          check "a fork's release by a reader: refused"      "$out" "has 'read' access"
put release.json '{"draft":true}'
out=$(run push refs/tags/v1.10.0 ann);          check "a fork's tag with no published release: refused" "$out" 'not a published release'
good; rm "$FAKE/repo.json"
out=$(run push refs/tags/v1.10.0);              check "fork unknown: refused"                      "$out" 'does not deploy when unsure'

echo "release-check: $pass passed, $failn failed"
[ "$failn" = 0 ]
