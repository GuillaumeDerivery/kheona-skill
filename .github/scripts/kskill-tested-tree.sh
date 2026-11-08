# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# The gate runs once per tree: a push to the default branch whose tree a green `Kheona Skill · PR` run already
# tested skips the rest of its CI (kskill-main.yml's call, before the staging deploy). Run by every kskill-ci-*
# copy's first job, from the repository root.
#   record  (a pull_request run): writes tree=<the checked-out tree> and file=<a small file naming it> to
#           $GITHUB_OUTPUT; the job uploads that file as the artifact `kskill-tested-tree-<tree>` (the PR run's checkout
#           is the PR merged into its base: the tree it tests).
#   find    (any other run): writes reused=true|false, and with true run=<url> and pr=<number>. Reuses only when
#           every condition holds, else runs the gate in full ("never skip when unsure"): the event is a push (a
#           called run's event is its caller's) to the default branch (never a version tag: a release always runs the full
#           gate; never a dispatch); an unexpired artifact of that name belongs to a `pull_request` run of
#           .github/workflows/kskill-pr.yml from this repository; and that run's CI jobs (`CI / ...`) are all
#           completed, each success or skipped, one at least a success. Any API error: the gate runs.
# A squash merge of an up-to-date PR has the tree its PR run tested; a PR behind its base does not, and runs in full.
# Env (find): GH_TOKEN (actions: read), GH_REPO, EVENT_NAME, GITHUB_REF, DEFAULT_BRANCH. Never writes to GitHub.
set -uo pipefail

mode=${1:?usage: kskill-tested-tree.sh record|find}
out=${GITHUB_OUTPUT:-/dev/stdout}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
tree=$(git rev-parse 'HEAD^{tree}' 2>/dev/null) || tree=""

if [ "$mode" = record ]; then
  [ -n "$tree" ] || { echo "::error::No checked-out tree to record."; exit 1; }
  file="${RUNNER_TEMP:-/tmp}/kskill-tested-tree.txt"
  printf 'tree %s\ncommit %s\n' "$tree" "$(git rev-parse HEAD)" > "$file"
  { echo "tree=$tree"; echo "file=$file"; } >> "$out"
  echo "Tested tree $tree (artifact kskill-tested-tree-$tree)."
  exit 0
fi
[ "$mode" = find ] || { echo "::error::usage: kskill-tested-tree.sh record|find" >&2; exit 64; }

full() { echo "The gate runs in full: $1."; echo "reused=false" >> "$out"; exit 0; }
[ "${EVENT_NAME:-}" = push ] || full "a ${EVENT_NAME:-?} run never reuses a PR run"
[ -n "${DEFAULT_BRANCH:-}" ] && [ "${GITHUB_REF:-}" = "refs/heads/$DEFAULT_BRANCH" ] ||
  full "only a push to the default branch reuses a PR run (${GITHUB_REF:-?}: a version tag and every other ref run in full)"
[ -n "$tree" ] || full "no checked-out tree"

ids=$(gh api "repos/$GH_REPO/actions/artifacts?name=kskill-tested-tree-$tree&per_page=30" \
  --jq '[.artifacts[] | select(.expired | not) | .workflow_run.id] | unique | reverse | .[]' 2>/dev/null) ||
  full "the artifacts are unreadable"
[ -n "$ids" ] || full "no Kheona Skill · PR run tested tree $tree"
for id in $ids; do
  [[ "$id" =~ ^[0-9]+$ ]] || continue
  run=$(gh api "repos/$GH_REPO/actions/runs/$id" \
    --jq '{event, path, repo: .head_repository.full_name, url: .html_url, pr: (.pull_requests[0].number // "")}' 2>/dev/null) || continue
  [ "$(jq -r .event <<<"$run")" = pull_request ] || continue
  [ "$(jq -r .path <<<"$run")" = .github/workflows/kskill-pr.yml ] || continue
  [ "$(jq -r .repo <<<"$run")" = "$GH_REPO" ] || continue
  ci=$(gh api "repos/$GH_REPO/actions/runs/$id/jobs?per_page=100" \
    --jq '[.jobs[] | select(.name | startswith("CI / "))]
      | if length > 0 and all(.status == "completed" and (.conclusion == "success" or .conclusion == "skipped"))
          and any(.conclusion == "success") then "green" else "not green" end' 2>/dev/null) || continue
  [ "$ci" = green ] || continue
  url=$(jq -r .url <<<"$run"); pr=$(jq -r .pr <<<"$run")
  { echo "reused=true"; echo "run=$url"; echo "pr=$pr"; } >> "$out"
  from="Kheona Skill · PR run $url"; [ -z "$pr" ] || from="$from (PR #$pr)"
  echo "Reused: $from passed CI on this exact tree ($tree): the rest of this gate is skipped." | tee -a "$summary"
  exit 0
done
full "no green Kheona Skill · PR run among those that tested tree $tree"
