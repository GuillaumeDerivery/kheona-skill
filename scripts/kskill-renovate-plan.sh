#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Plans .github/workflows/renovate.yml: one Renovate run per owner the automation App is installed on (an
# installation token reaches one owner). Writes <out>/owners.json (the owners with something to process) and, per owner,
# <out>/renovate-<owner>.json, the self-hosted (global) configuration of its run:
#   - repositories: scripts/kskill-repos.sh --topic kheona-skill --forks exclude (forks get their updates through their
#     upstream sync), plus kheona-skill itself; REPOSITORIES narrows it. Only those carrying a renovate.json are
#     processed (requireConfig), never onboarded;
#   - lib's rule 1: in every repository whose .gitmodules points at the library repository, the packages lib's
#     package.json names (read from lib's default branch now) are left alone: they follow lib through bump-lib;
#   - kheona-skill's PR writes the callers again (postUpgradeTasks, once per branch): Renovate moves their pins, then
#     scripts/kskill-callers-regenerate.mjs runs the generator of the version they now name. allowedCommands allows
#     that one command, exactly, and nothing else;
#   - the commits are the App's; DRY_RUN=full turns Renovate's dryRun on.
# Usage: kskill-renovate-plan.sh <out-dir>
# Env: KSKILL_APP_TOKENS (tokens.json of .github/scripts/kskill-app-tokens.mjs), REPOSITORIES (optional, space-separated),
#      DRY_RUN (optional, "full"), KSKILL_SHA (optional, the running commit: a warning when the latest release is ahead). Prints a summary in Markdown. No token is written to the files.
set -euo pipefail
OUT=${1:?usage: kskill-renovate-plan.sh <out-dir>}
HERE=$(cd "$(dirname "$0")" && pwd)
SKILL_REPO=${KSKILL_REPO:-}
LIB=${KSKILL_LIB_REPO:-}
BOT=${KSKILL_BOT:?KSKILL_BOT, the login of the App, is required}
: "${KSKILL_APP_TOKENS:?KSKILL_APP_TOKENS (tokens.json of kskill-app-tokens.mjs) is required}"
mkdir -p "$OUT"
token_of() { jq -r --arg o "${1,,}" '.[$o] // empty' "$KSKILL_APP_TOKENS"; }
api() { curl -fsS ${1:+-H "Authorization: Bearer $1"} "https://api.github.com/$2" 2>/dev/null; }
raw() { curl -fsS -H "Authorization: Bearer $1" -H 'Accept: application/vnd.github.raw' "https://api.github.com/repos/$2/contents/$3"; }

if [ -n "${REPOSITORIES:-}" ]; then
  read -r -a repos <<<"$REPOSITORIES"
else
  mapfile -t repos < <(bash "$HERE/kskill-repos.sh" --topic kheona-skill --forks exclude; [ -z "$SKILL_REPO" ] || echo "$SKILL_REPO")
fi

# The App's commits and its Dependency Dashboard: Renovate finds its own issues by this login, so it must be the App's.
BOT_ID=$(curl -fsS "https://api.github.com/users/$(jq -rn --arg b "$BOT" '$b|@uri')" | jq -r .id)
[ -n "$BOT_ID" ] && [ "$BOT_ID" != null ] || { echo "::error::No GitHub user $BOT" >&2; exit 1; }

# This run writes its PRs with this version's plan, the callers' regeneration included: a caller pinned behind the
# latest release opens that release's PRs without what the release changed here (v2.7.0's PRs, opened by v2.6.1's plan,
# kept the callers of v2.6.x). KSKILL_SHA, the running commit, is compared with the latest release; behind it, a warning.
behind=0; latest=''
if [[ "${KSKILL_SHA:-}" =~ ^[0-9a-f]{40}$ ]] && [ -n "$SKILL_REPO" ]; then
  skill_token=$(token_of "${SKILL_REPO%%/*}")
  latest=$(api "$skill_token" "repos/$SKILL_REPO/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null) || latest=''
  if [ -n "$latest" ]; then
    behind=$(api "$skill_token" "repos/$SKILL_REPO/compare/$KSKILL_SHA...$latest" | jq -r '.ahead_by // 0' 2>/dev/null) || behind=0
    [[ "$behind" =~ ^[0-9]+$ ]] || behind=0
  fi
fi

# The callers' regeneration: the script on one line, its comment lines dropped (see its header).
regen_cmd="node --input-type=module -e '$(grep -v '^//' "$HERE/kskill-callers-regenerate.mjs" | sed 's/^ *//' | tr '\n' ' ' | sed 's/ *$//')'"

lib_token=$(token_of "${LIB%%/*}")
lib_packages=$(raw "$lib_token" "$LIB" package.json |
  jq -c '[(.dependencies, .devDependencies, .peerDependencies, .optionalDependencies) // {} | keys[]] | unique')
consumers='[]'
for r in "${repos[@]}"; do
  t=$(token_of "${r%%/*}"); [ -n "$t" ] || continue
  if raw "$t" "$r" .gitmodules 2>/dev/null | grep -qiE "url *= *.*[/:]$LIB(\.git)? *$"; then consumers=$(jq -c --arg r "$r" '. + [$r]' <<<"$consumers"); fi
done

echo '## Renovate plan'
echo
if [ "$behind" -gt 0 ]; then
  echo "::warning::This run is $SKILL_REPO at ${KSKILL_SHA:0:7}, $behind commit(s) behind its latest release $latest: its PRs to $latest are written by this older plan (the callers' regeneration included). Move the caller of this workflow to $latest first." >&2
  echo "**Behind:** this run is $SKILL_REPO at \`${KSKILL_SHA:0:7}\`, $behind commit(s) behind $latest; its PRs to $latest are written by this older plan. Move this workflow's caller to $latest first."
  echo
fi
echo "lib's packages left to bump-lib in $(jq length <<<"$consumers") consumer(s): $(jq -r 'join(", ")' <<<"$consumers")"
owners='[]'
for owner in $(printf '%s\n' "${repos[@]}" | cut -d/ -f1 | sort -fu); do
  [ -n "$(token_of "$owner")" ] || { echo "- $owner: the App is not installed there, skipped"; continue; }
  mine=$(printf '%s\n' "${repos[@]}" | awk -F/ -v o="$owner" 'tolower($1) == tolower(o)' | jq -Rnc '[inputs]')
  jq -n --argjson repos "$mine" --argjson consumers "$consumers" --argjson pkgs "$lib_packages" --arg dry "${DRY_RUN:-}" --arg bot "$BOT" --arg author "$BOT <$BOT_ID+$BOT@users.noreply.github.com>" --arg regen "$regen_cmd" '{
    platform: "github",
    username: $bot,
    gitAuthor: $author,
    onboarding: false,
    requireConfig: "required",
    repositories: $repos,
    cloneSubmodules: true,
    npmrc: "allow-git=all\n",
    npmrcMerge: true,
    allowedCommands: ["^" + ($regen | gsub("(?<c>[.*+?^${}()|\\[\\]\\\\/])"; "\\\(.c)")) + "$"],
    packageRules: ([{
      description: "kheona-skill'"'"'s PR: the callers written again by the version they now name (scripts/kskill-callers-regenerate.mjs).",
      matchDepNames: ["/(^|/)kheona-skill(/|$)/"],
      postUpgradeTasks: { commands: [$regen], executionMode: "branch", fileFilters: [".github/workflows/kskill-*.yml", ".github/workflows/kskill-*.yaml", "renovate.json"] } }]
      + (if ($consumers | length) == 0 then [] else [{
      description: "lib rule 1: a lib consumer keeps every package lib names at lib'"'"'s exact version; the inbox job bump-lib moves them.",
      matchRepositories: $consumers, matchPackageNames: $pkgs, enabled: false }] end))
  } + (if $dry == "" then {} else {dryRun: $dry} end)' > "$OUT/renovate-$owner.json"
  owners=$(jq -c --arg o "$owner" '. + [$o]' <<<"$owners")
  echo "- $owner: $(jq -r 'join(", ")' <<<"$mine")"
done
echo "$owners" > "$OUT/owners.json"
