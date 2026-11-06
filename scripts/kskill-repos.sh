#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The one definition of "the Kheona repositories": every repository the token reaches (owner, collaborator,
# organisation member) that is not archived, optionally filtered on a GitHub topic and on fork-ness.
# Callers: the Renovate plan, the map collector (which
# the doctor plans and audits from) and lib's release notice (its `Kheona Skill · Release`).
#
# Usage: kskill-repos.sh [--topic <topic>] [--forks include|exclude|only] [--exclude <owner/repo>]... [--json]
#                        [--from <file>]
#   --topic    keep the repositories carrying this topic (kheona-skill: in the skill's scope; kheona-lib: receive
#              lib's releases). Without it, every reachable non-archived repository.
#   --forks    include (default), exclude or only the forks.
#   --exclude  leave this repository out (repeatable), e.g. the caller itself.
#   --json     a JSON array of {full_name, fork, topics, html_url, default_branch}; default: one owner/repo per line.
#   --from     read the listing from this file (what `gh api --paginate --slurp user/repos...` printed, or a plain
#              array) instead of calling GitHub: a caller filters one listing several ways for one API pass.
# Env: KSKILL_APP_TOKENS (the tokens.json of .github/scripts/kskill-app-tokens.mjs: every repository the
#      the automation App is installed on, per owner; the installation listing has no topics, so each non-archived
#      repository's are read), else GH_TOKEN or `gh` signed in (every repository the user reaches).
#      Output sorted by full_name. Exit 1 when GitHub cannot be listed.
#
# Not the search API: its index of private repositories is unreliable (the same query returned 8 repositories,
# then 0, on 2026-10-22).
set -euo pipefail

usage() { sed -n '7,8p' "$0" | sed 's/^# //' >&2; exit 64; }
topic="" forks=include json=false from=""
excludes='[]'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --topic) topic=${2:?--topic needs a value}; shift 2 ;;
    --forks) forks=${2:?--forks needs a value}; shift 2 ;;
    --exclude) excludes=$(jq -c --arg r "${2:?--exclude needs a value}" '. + [$r]' <<<"$excludes"); shift 2 ;;
    --json) json=true; shift ;;
    --from) from=${2:?--from needs a value}; shift 2 ;;
    -h|--help) usage ;;
    *) echo "kskill-repos.sh: unknown argument $1" >&2; usage ;;
  esac
done
case "$forks" in include|exclude|only) ;; *) echo "kskill-repos.sh: --forks is include, exclude or only" >&2; exit 64 ;; esac

# get <token> <path>: the API with one installation's token (curl: a gh wrapper would pick its own token).
get() { curl -fsS -H "Authorization: Bearer $1" -H 'Accept: application/vnd.github+json' "https://api.github.com/$2"; }
if [ -n "$from" ]; then
  listing=$(cat "$from")
elif [ -n "${KSKILL_APP_TOKENS:-}" ]; then
  listing='[]'
  while IFS= read -r token; do
    page=1
    while :; do
      batch=$(get "$token" "installation/repositories?per_page=100&page=$page" | jq -c '.repositories') || exit 1
      while IFS= read -r name; do
        topics=$(get "$token" "repos/$name/topics" | jq -c '.names') || exit 1
        batch=$(jq -c --arg n "$name" --argjson t "$topics" 'map(if .full_name == $n then .topics = $t else . end)' <<<"$batch")
      done < <(jq -r '.[] | select(.archived | not) | .full_name' <<<"$batch")
      listing=$(jq -c --argjson b "$batch" '. + $b' <<<"$listing")
      [ "$(jq length <<<"$batch")" -eq 100 ] || break
      page=$((page + 1))
    done
  done < <(jq -r '.[]' "$KSKILL_APP_TOKENS")
else
  listing=$(gh api --paginate --slurp 'user/repos?per_page=100&affiliation=owner,collaborator,organization_member')
fi

# A topic matches any of its accepted spellings (kskill-topics.json: kheona-skill or kskill, kheona-lib or klib).
names=$(jq -c --arg t "$topic" '.[$t] // [$t]' "$(cd "$(dirname "$0")" && pwd)/kskill-topics.json")
# shellcheck disable=SC2016  # why: $topic, $names, $forks and $ex are jq variables, not shell ones
filter='
  (if (.[0]? | type) == "array" then add else . end) // []
  | map(select(.archived | not))
  | map(select($topic == "" or ((.topics // []) as $ts | $names | any(. as $n | $ts | index($n)))))
  | map(select($forks == "include" or ($forks == "only") == (.fork == true)))
  | map(select(.full_name as $n | $ex | index($n) | not))
  | unique_by(.full_name)
  | map({full_name, fork: (.fork == true), topics: (.topics // []), html_url, default_branch})'
out=$(jq -c --arg topic "$topic" --argjson names "$names" --arg forks "$forks" --argjson ex "$excludes" "$filter" <<<"$listing")
if [ "$json" = true ]; then echo "$out"; else jq -r '.[].full_name' <<<"$out"; fi
