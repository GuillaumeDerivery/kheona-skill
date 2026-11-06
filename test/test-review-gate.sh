#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline test of the Claude review's gate on automation PRs: the steps' own scripts, extracted from kskill-pr.yml, run
# against a fake gh.
#   - review job, "Post or update the review comment": a blocking verdict drafts the PR with the App token, and says so
#     (a warning, and the comment) when it cannot; nothing is dispatched (the merge job runs next in the same run).
#   - merge job, "Read the configuration" (whether the review runs here, release-please's settings) and "Check the PR": a
#     blocking or needs-person verdict at the head stops every branch kind, a labelled renovate/ or chore/bump-lib PR
#     needs the verdict at its head where the review runs, kskill/sync never does, release-please's PR merges on its
#     gate in a library.
set -uo pipefail
export KSKILL_REPO=owner/kheona-skill KSKILL_BOT='example-app[bot]'
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
check() { # check <name> <output> <grep -E pattern> [absent]
  if { [ "${4:-}" = absent ] && ! grep -qE "$3" <<<"$2"; } || { [ "${4:-}" != absent ] && grep -qE "$3" <<<"$2"; }; then
    pass=$((pass+1)); echo "ok   $1"
  else failn=$((failn+1)); echo "FAIL $1 (pattern $3${4:+, $4})"; printf '     %s\n' "${2//$'\n'/$'\n'     }"; fi
}

# A step's script: the `run: |` block after `- name: <name>`, up to the first non-empty line indented less, de-indented.
extract() { # extract <template> <step name> <out>
  awk -v name="- name: $2" '
    index($0, name) { f = 1; next }
    f && !r && /run: \|/ { r = 1; next }
    r && /^$/ { print; next }
    r && !/^          / { exit }
    r { sub(/^          /, ""); print }' "$HERE/.github/workflows/$1" > "$3"
  [ -s "$3" ] || { echo "FAIL could not extract \"$2\" from $1"; exit 1; }
}
extract kskill-pr.yml 'Post or update the review comment' "$T/comment.sh"
extract kskill-pr.yml 'Read the configuration' "$T/config.sh"
extract kskill-pr.yml 'Check the PR' "$T/check.sh"

# Fake gh: answers from $FAKE, records what it is asked to do in $FAKE/log (with the token in use).
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
jqx=.; args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[i]}" = --jq ] && jqx=${args[i+1]}; done
out() { [ -f "$FAKE/$1" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; jq -r "$jqx" "$FAKE/$1"; }
case "$1 $2" in
  "pr ready")
    echo "ready $* token=$GH_TOKEN" >> "$FAKE/log"
    [ -f "$FAKE/ready-refused" ] && { echo "API call failed: GraphQL: Resource not accessible by integration (convertPullRequestToDraft)" >&2; exit 1; }
    exit 0 ;;
  "workflow run") echo "dispatch $*" >> "$FAKE/log"; exit 0 ;;
  "pr view")
    case "$*" in *"--json isDraft "*) out draft.json ;; *"--json files "*) out files.json ;; *) out pr.json ;; esac ;;
  "pr list") jq -c '[.]' "$FAKE/pr.json" > "$FAKE/prs.json"; out prs.json ;;
  "issue view") out issue.json ;;
  "run list") out ci.json ;;
  api*)
    path=""; method=GET
    for ((i = 1; i < ${#args[@]}; i++)); do case "${args[i]}" in
      -f) [[ "${args[i+1]}" == body=* ]] && printf '%s\n' "${args[i+1]#body=}" >> "$FAKE/body"; i=$((i+1)) ;;
      --jq) i=$((i+1)) ;; -X) method=${args[i+1]}; i=$((i+1)) ;; -*) ;; *) [ -n "$path" ] || path=${args[i]} ;; esac; done
    if [ "$method" != GET ]; then echo "api $method $path" >> "$FAKE/log"; exit 0; fi
    case "$path" in
      */issues/*/comments) out comments.json ;;
      */contents/.kheona.json*) out kheona.json ;;
      */contents/.github/workflows*) out workflows.json ;;
      *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    esac ;;
  *) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
GH
chmod +x "$T/bin/gh"
FAKE="$T/fake"
put() { printf '%s' "$2" > "$FAKE/$1"; }
reset() { rm -rf "$FAKE"; mkdir -p "$FAKE"; : > "$FAKE/log"; put draft.json '{"isDraft":false}'; put comments.json '[]'; }

HEAD=1111111111111111111111111111111111111111
OLD=2222222222222222222222222222222222222222

# ---- The review's comment step ------------------------------------------------------------------------------------
review() { # review <verdict> [env...]: run the comment step on a successful review returning <verdict>
  local v=$1; shift
  (cd "$T" && env PATH="$T/bin:$PATH" FAKE="$FAKE" GH_REPO=o/r NUMBER=7 HEAD_SHA=$HEAD GH_TOKEN=gha OUTCOME=success \
    RESULT="{\"verdict\":\"$v\",\"findings\":[{\"path\":\"Dockerfile\",\"line\":1,\"issue\":\"breaks the build\"}]}" \
    EVENT_ACTION=synchronize DEFAULT_BRANCH=main RUN_URL=https://run GITHUB_STEP_SUMMARY=/dev/null "$@" bash -e comment.sh 2>&1)
}
reset; review blocking APP_TOKEN=app > /dev/null; out=$(cat "$FAKE/body"); log=$(cat "$FAKE/log")
check "blocking: drafted with the App token, never GITHUB_TOKEN"  "$log" '^ready pr ready 7 --undo token=app$'
check "blocking: the comment says it was drafted"                  "$out" 'Converted to draft'
check "blocking: the verdict line names the head"                  "$out" "^<!-- kskill-claude-review-verdict: blocking $HEAD -->$"
check "blocking: nothing dispatched"                              "$log" '^dispatch' absent
check "blocking: the draft comes before the comment"               "$(grep -nE '^(ready|api POST)' "$FAKE/log" | head -1)" '^1:ready'

reset; touch "$FAKE/ready-refused"; out=$(review blocking APP_TOKEN=app); log=$(cat "$FAKE/log")
check "draft refused: a warning, not a silent pass"                "$out" '^::warning::Blocking verdict on #7, but GitHub refused'
check "draft refused: the comment says so"                         "$(cat "$FAKE/body")" 'Could not convert it to a draft'
check "draft refused: the comment does not claim a draft"          "$(cat "$FAKE/body")" 'Converted to draft' absent
check "draft refused: the comment is still posted"                 "$log" '^api POST repos/o/r/issues/7/comments$'

reset; out=$(review blocking APP_TOKEN=); log=$(cat "$FAKE/log")
check "no App token: a warning naming the secrets"                 "$out" '^::warning::.*no App token \(secrets KSKILL_TOKEN_BROKER_URL'
check "no App token: no draft attempted with GITHUB_TOKEN"         "$log" '^ready' absent

reset; put draft.json '{"isDraft":true}'; out=$(review blocking APP_TOKEN=app)
check "already a draft: nothing to convert"                        "$(cat "$FAKE/log")" '^ready' absent
reset; review blocking APP_TOKEN=app EVENT_ACTION=ready_for_review > /dev/null
check "marked ready by a person: never drafted again"              "$(cat "$FAKE/log")" '^ready' absent
check "marked ready by a person: never merged automatically"       "$(cat "$FAKE/body")" 'it is never merged automatically'

reset; review ok > /dev/null
check "ok: the verdict line, nothing dispatched"                   "$(cat "$FAKE/body")" "^<!-- kskill-claude-review-verdict: ok $HEAD -->$"
check "ok: nothing dispatched (the merge job runs next)"           "$(cat "$FAKE/log")" '^dispatch' absent
reset; (cd "$T" && env PATH="$T/bin:$PATH" FAKE="$FAKE" GH_REPO=o/r NUMBER=7 HEAD_SHA=$HEAD OUTCOME=failure RESULT= \
  EVENT_ACTION=synchronize DEFAULT_BRANCH=main RUN_URL=u GITHUB_STEP_SUMMARY=/dev/null bash -e comment.sh > "$T/out" 2>&1)
check "failed: the verdict line says failed"                       "$(cat "$FAKE/body")" "^<!-- kskill-claude-review-verdict: failed $HEAD -->$"
check "failed: nothing dispatched"                                 "$(cat "$FAKE/log")" '^dispatch' absent

# ---- The merge job's configuration: does the review run here? release-please's settings ----------------------------
config() { (cd "$T" && : > "$T/output" && env PATH="$T/bin:$PATH" FAKE="$FAKE" GH_REPO=o/r GH_TOKEN=gha DEFAULT_BRANCH=main \
  GITHUB_OUTPUT="$T/output" GITHUB_STEP_SUMMARY=/dev/null "$@" bash -eo pipefail config.sh 2>&1 && cat "$T/output"); }
kheona() { put kheona.json "{\"content\":\"$(printf '%s' "$1" | base64 | tr -d '\n')\"}"; }
reset; kheona '{"role":"library"}'
put workflows.json '[{"name":"kskill-ci.yml"},{"name":"kskill-pr.yml"}]'
out=$(config HAS_REVIEW_TOKEN=true)
check "config: only kskill- workflows (pipefail-safe), reviewed here" "$out" '^review=true$'
check "config: a library stays staging-only"                        "$out" '^staging_only=true$'
check "config: release-please defaults (merge gate, gate kskill-pr.yml)" "$out" '^rp_merge=gate$'
check "... the gate"                                                "$out" '^rp_gate=kskill-pr.yml$'
check "... the phase defaults to established"                    "$out" '^phase=established$'
out=$(config HAS_REVIEW_TOKEN=false)
check "config: no review token, no review expected"                 "$out" '^review=false$'
put workflows.json '[{"name":"kskill-ci.yml"},{"name":"deploy.yml"}]'
kheona '{"phase":"bootstrap","workflows":{"cd":{"enabled":true},"releasePlease":{"merge":"daily","gate":"ci.yml"}}}'
out=$(config HAS_REVIEW_TOKEN=true)
check "config: a workflow of its own is named"                      "$out" '^deploy_note=workflows of its own \(deploy.yml\)'
check "config: release-please's merge mode read"                    "$out" '^rp_merge=daily$'
check "config: ... its gate"                                        "$out" '^rp_gate=ci.yml$'
check "config: ... the phase"                                       "$out" '^phase=bootstrap$'

# ---- The merge job's PR check -------------------------------------------------------------------------------------
pr() { # pr <branch> [label] [author]: label y = automerge, any other value is that label's name
  local labels=""; case "${2:-}" in "") ;; y) labels='{"name":"automerge"}' ;; *) labels="{\"name\":\"$2\"}" ;; esac
  put pr.json "{\"number\":7,\"author\":{\"login\":\"${3:-app/example-app}\"},\"headRefName\":\"$1\",\"headRefOid\":\"$HEAD\",\"baseRefName\":\"main\",\"isDraft\":false,\"isCrossRepository\":false,\"labels\":[$labels],\"state\":\"OPEN\"}"
  put files.json '{"files":[{"path":"package.json"}]}'
}
verdict() { # verdict <said> <sha> [user]
  put comments.json "[{\"user\":{\"login\":\"${3:-github-actions[bot]}\"},\"body\":\"<!-- kskill-claude-review -->\\n**Claude review**\\n\\n<!-- kskill-claude-review-verdict: $1 $2 -->\"}]"
}
merge() { # merge <branch> [env...]: run the check in the run that tested $HEAD; prints the outcome
  shift
  (cd "$T" && : > "$T/output" && env PATH="$T/bin:$PATH" FAKE="$FAKE" GH_REPO=o/r GH_TOKEN=gha DEFAULT_BRANCH=main FORK=false \
    NUMBER=7 TESTED=$HEAD STAGING_ONLY=true DEPLOY_NOTE=x REVIEWED_HERE=true ROLE=project RP_MERGE=gate RP_GATE=kskill-pr.yml \
    PHASE=established GITHUB_OUTPUT="$T/output" GITHUB_STEP_SUMMARY=/dev/null "$@" bash check.sh 2>&1; cat "$T/output")
}
R=renovate/npm-minor-patch
reset; pr $R y; verdict blocking $HEAD
check "renovate, blocking at head: skipped"                         "$(merge $R)" 'Claude review: blocking at 1111111, left for a person|Claude review: blocking at '"$HEAD"
check "renovate, blocking at head: not eligible"                    "$(merge $R)" '^number=' absent
reset; pr $R y; verdict needs-person $HEAD
check "renovate, needs-person at head: skipped"                     "$(merge $R)" 'Claude review: needs-person at'
reset; pr $R y; verdict ok $HEAD
check "renovate, ok at head: merged"                                "$(merge $R)" '^number=7$'
reset; pr $R y; verdict failed $HEAD
check "renovate, review failed at head: CI alone decides"           "$(merge $R)" '^number=7$'
reset; pr $R y
check "renovate, no verdict at its head: not merged"                "$(merge $R)" 'no Claude review of'
check "renovate, no review here: CI alone decides"                  "$(merge $R REVIEWED_HERE=false)" '^number=7$'
reset; pr $R y; verdict blocking $OLD
check "renovate, blocking on an older commit: not this one's"       "$(merge $R)" 'no Claude review of'
check "renovate, older verdict and no review here: merged"          "$(merge $R REVIEWED_HERE=false)" '^number=7$'
reset; pr $R y; verdict blocking $HEAD 'someone'
check "renovate, a verdict line by anyone else is ignored"          "$(merge $R)" 'no Claude review of'
reset; pr $R
check "renovate, unlabelled: skipped"                               "$(merge $R)" 'not labelled automerge'
reset; pr chore/bump-lib y; verdict blocking $HEAD
check "bump-lib, blocking at head: skipped"                         "$(merge chore/bump-lib)" 'Claude review: blocking at'
reset; pr chore/bump-lib y
check "bump-lib, no verdict at its head: not merged"                "$(merge chore/bump-lib)" 'no Claude review of'
reset; pr doctor/fix-x; verdict ok $HEAD
check "doctor, ok at head: merged"                                  "$(merge doctor/fix-x)" '^number=7$'
reset; pr doctor/fix-x; verdict blocking $HEAD
check "doctor, blocking at head: skipped"                           "$(merge doctor/fix-x)" 'Claude review: blocking at'
reset; pr doctor/fix-x
check "doctor, no verdict: skipped"                                 "$(merge doctor/fix-x)" 'no Claude review verdict'
reset; pr doctor/fix-x; verdict ok $OLD
check "doctor, ok on an older commit: skipped"                      "$(merge doctor/fix-x)" "the Claude review is of $OLD, not $HEAD"
reset; pr doctor/fix-x; verdict failed $HEAD
check "doctor, review failed: skipped"                              "$(merge doctor/fix-x)" 'Claude review: failed, left for a person'
reset; pr doctor/fix-x; verdict ok $HEAD
check "a head that moved past the tested commit: skipped"          "$(merge doctor/fix-x TESTED=$OLD)" 'moved past the commit this run tested'
P=release-please--branches--main
reset; pr $P 'autorelease: pending'
check "release-please, a library on its gate: merged"              "$(merge $P ROLE=library)" '^number=7$'
check "release-please, squashed"                                   "$(merge $P ROLE=library)" '^method=--squash$'
check "release-please outside a library: skipped"                  "$(merge $P)" 'outside a library'
check "release-please, merge daily: left to Kheona Skill · Release" "$(merge $P ROLE=library RP_MERGE=daily)" 'merge is daily'
check "release-please, another gate: left to Kheona Skill · Release" "$(merge $P ROLE=library RP_GATE=ci.yml)" 'gate is ci.yml'
check "release-please, bootstrap phase: held"                      "$(merge $P ROLE=library PHASE=bootstrap)" 'bootstrap phase'
reset; pr $P
check "release-please, unlabelled: skipped"                        "$(merge $P ROLE=library)" 'not labelled autorelease: pending'
reset; pr $P 'autorelease: pending' someone
check "release-please, not example-app's: skipped"                  "$(merge $P ROLE=library)" 'opened by someone'

echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
