# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# Which environment a run deploys, from its ref alone, and whether a production run may go ahead. Run by the plan
# job of kskill-deploy.yml and the config job of kskill-deliver-flutter.yml, before anything is built.
#   refs/heads/<default branch>, push or dispatch         -> staging (a test build, for an app)
#   pull_request, only with DRY_RUN=true                  -> staging, nothing deployed
#   refs/tags/vX.Y.Z, push (the release) or dispatch      -> prod, once every check below passes
#   anything else                                         -> refused
# A tag can be pushed by anyone with write access, and tags cannot be protected on every plan, so production
# checks, in this order, and fails on the first that does not hold (any API error fails too: never deploy when unsure):
#   1. the ref is refs/tags/vMAJOR.MINOR.PATCH, nothing looser;
#   2. the tagged commit is on the default branch (the compare API: the checkout is shallow);
#   3. a push (the release): the tag is the newest version tag, and the commit is the squash merge of a
#      release-please PR of this repository, merged by a person (not a bot) with write access;
#      a dispatch (a rollback, or the same release again), or a push in a fork (release-please never runs in one: a
#      person publishes the parent's version there): the tag is a published release, and the person who started the
#      run (triggering_actor) has write access;
#   4. a push outside a fork: Kheona Skill · Main passed on the commit before the release (its staging deploy included): the release
#      commit only changes the version and the CHANGELOG, and never ran on staging itself. While that run is still going
#      (the release PR merged right after another merge), it waits for it: KSKILL_MAIN_WAIT_SECONDS, default 2700.
# Writes environment=staging|prod and, for prod, version=<tag> to $GITHUB_OUTPUT; for a release (4), tested=<the commit
# before>, whose staging image production may reuse (kskill-release-image.sh).
# Env: GH_TOKEN (contents, pull-requests and actions read), GH_REPO, EVENT_NAME, GITHUB_REF, GITHUB_SHA,
# DEFAULT_BRANCH, ACTOR (github.triggering_actor), DRY_RUN. Never writes to GitHub.
set -uo pipefail

out=${GITHUB_OUTPUT:-/dev/stdout}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
fail() { echo "::error::$1" >&2; exit 1; }
api() { gh api "$@" 2>/dev/null || fail "GitHub API call failed (${1}): production does not deploy when unsure."; }
person() { # person <login>: a person, not a bot, with write access
  case "$1" in ''|*'[bot]') fail "${1:-nobody} is not a person: only a person releases to production." ;; esac
  local role; role=$(api "repos/$GH_REPO/collaborators/$1/permission" --jq .role_name)
  case "$role" in admin|maintain|write) ;; *) fail "$1 has '$role' access: releasing to production needs write." ;; esac
}

: "${GH_REPO:?}" "${EVENT_NAME:?}" "${GITHUB_REF:?}" "${GITHUB_SHA:?}"
main=${DEFAULT_BRANCH:-main}

case "$EVENT_NAME:$GITHUB_REF" in
  push:"refs/heads/$main"|workflow_dispatch:"refs/heads/$main")
    echo "environment=staging" >> "$out"; echo "Staging: $GITHUB_REF."; exit 0 ;;
  pull_request:*)
    [ "${DRY_RUN:-false}" = true ] || fail "A pull request only deploys as a dry run."
    echo "environment=staging" >> "$out"; exit 0 ;;
  push:refs/tags/*|workflow_dispatch:refs/tags/*) ;;
  *) fail "$EVENT_NAME on $GITHUB_REF deploys nothing: $main deploys staging, a version tag deploys production." ;;
esac

# 1
tag=${GITHUB_REF#refs/tags/}
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Tag $tag is not a version (vMAJOR.MINOR.PATCH): it deploys nothing."

# 2
status=$(api "repos/$GH_REPO/compare/$main...$GITHUB_SHA" --jq .status)
case "$status" in identical|behind) ;; *) fail "$tag ($GITHUB_SHA) is not on $main (compare: $status): it deploys nothing." ;; esac

fork=false
[ "$EVENT_NAME" = push ] && fork=$(api "repos/$GH_REPO" --jq .fork)
if [ "$EVENT_NAME" = push ] && [ "$fork" != true ]; then
  # 3, the release
  newest=$(api --paginate "repos/$GH_REPO/tags?per_page=100" --jq '.[].name' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1)
  [ "$newest" = "$tag" ] || fail "$tag is not the newest version ($newest): a rollback is started by hand on the tag."
  pr=$(api "repos/$GH_REPO/commits/$GITHUB_SHA/pulls" \
    --jq "[.[] | select(.merged_at != null and .merge_commit_sha == \"$GITHUB_SHA\" and .base.ref == \"$main\")] | .[0].number // empty")
  [ -n "$pr" ] || fail "$GITHUB_SHA is not the merge of a pull request into $main: only a merged release PR releases."
  read -r head head_repo merger merger_type < <(api "repos/$GH_REPO/pulls/$pr" \
    --jq '"\(.head.ref) \(.head.repo.full_name // "-") \(.merged_by.login // "-") \(.merged_by.type // "-")"')
  [[ "$head" == release-please--* ]] && [ "$head_repo" = "$GH_REPO" ] ||
    fail "PR #$pr ($head) is not this repository's release PR: only its merge releases."
  [ "$merger_type" = User ] || fail "PR #$pr was merged by $merger ($merger_type): only a person releases."
  person "$merger"
  # 4
  parent=$(api "repos/$GH_REPO/commits/$GITHUB_SHA" --jq '.parents[0].sha // empty')
  [ -n "$parent" ] || fail "$GITHUB_SHA has no parent to have been tested on staging."
  # A release PR merged while Main still runs on the commit before: wait for it rather than fail.
  waited=0; wait_max=${KSKILL_MAIN_WAIT_SECONDS:-2700}; every=${KSKILL_MAIN_WAIT_INTERVAL:-30}
  while :; do
    runs=$(api "repos/$GH_REPO/actions/runs?head_sha=$parent&event=push&per_page=50" \
      --jq "[.workflow_runs[] | select(.path == \".github/workflows/kskill-main.yml\" and .head_branch == \"$main\")]")
    [ -n "$runs" ] || fail "GitHub API call failed (runs of ${parent:0:7}): production does not deploy when unsure."
    passed=$(jq -r '[.[] | select(.conclusion == "success")] | .[0].html_url // empty' <<<"$runs")
    [ -n "$passed" ] && break
    running=$(jq -r '[.[] | select(.status != "completed")] | length' <<<"$runs")
    if [ "$running" = 0 ]; then
      fail "Kheona Skill · Main has not passed on ${parent:0:7}, the commit before $tag: production waits for staging. Re-run it, then start this workflow on $tag by hand."
    fi
    [ "$waited" -lt "$wait_max" ] ||
      fail "Kheona Skill · Main still runs on ${parent:0:7}, the commit before $tag, after $((waited / 60)) min. Once it passes, start this workflow on $tag by hand."
    echo "Kheona Skill · Main still runs on ${parent:0:7}, the commit before $tag: waiting (${waited}s)."
    sleep "$every"; waited=$((waited + every))
  done
  echo "Release $tag: PR #$pr merged by $merger; staging passed on ${parent:0:7} ($passed)." | tee -a "$summary"
  echo "tested=$parent" >> "$out"
else
  # 3, a rollback, the same release again, or a fork's release
  draft=$(api "repos/$GH_REPO/releases/tags/$tag" --jq .draft)
  [ "$draft" = false ] || fail "$tag is not a published release."
  person "${ACTOR:-}"
  if [ "$fork" = true ]; then echo "Fork release $tag published by ${ACTOR}." | tee -a "$summary"
  else echo "Deploy of $tag started by ${ACTOR}." | tee -a "$summary"; fi
fi
{ echo "environment=prod"; echo "version=$tag"; } >> "$out"
