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
#   - the commits are the App's; DRY_RUN=full turns Renovate's dryRun on.
# Usage: kskill-renovate-plan.sh <out-dir>
# Env: KSKILL_APP_TOKENS (tokens.json of .github/scripts/kskill-app-tokens.mjs), REPOSITORIES (optional, space-separated),
#      DRY_RUN (optional, "full"). Prints a summary in Markdown. No token is written to the files.
set -euo pipefail
OUT=${1:?usage: kskill-renovate-plan.sh <out-dir>}
HERE=$(cd "$(dirname "$0")" && pwd)
SKILL_REPO=${KSKILL_REPO:-}
LIB=${KSKILL_LIB_REPO:-}
BOT=${KSKILL_BOT:?KSKILL_BOT, the login of the App, is required}
: "${KSKILL_APP_TOKENS:?KSKILL_APP_TOKENS (tokens.json of kskill-app-tokens.mjs) is required}"
mkdir -p "$OUT"
token_of() { jq -r --arg o "${1,,}" '.[$o] // empty' "$KSKILL_APP_TOKENS"; }
raw() { curl -fsS -H "Authorization: Bearer $1" -H 'Accept: application/vnd.github.raw' "https://api.github.com/repos/$2/contents/$3"; }

if [ -n "${REPOSITORIES:-}" ]; then
  read -r -a repos <<<"$REPOSITORIES"
else
  mapfile -t repos < <(bash "$HERE/kskill-repos.sh" --topic kheona-skill --forks exclude; [ -z "$SKILL_REPO" ] || echo "$SKILL_REPO")
fi

# The App's commits and its Dependency Dashboard: Renovate finds its own issues by this login, so it must be the App's.
BOT_ID=$(curl -fsS "https://api.github.com/users/$(jq -rn --arg b "$BOT" '$b|@uri')" | jq -r .id)
[ -n "$BOT_ID" ] && [ "$BOT_ID" != null ] || { echo "::error::No GitHub user $BOT" >&2; exit 1; }

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
echo "lib's packages left to bump-lib in $(jq length <<<"$consumers") consumer(s): $(jq -r 'join(", ")' <<<"$consumers")"
owners='[]'
for owner in $(printf '%s\n' "${repos[@]}" | cut -d/ -f1 | sort -fu); do
  [ -n "$(token_of "$owner")" ] || { echo "- $owner: the App is not installed there, skipped"; continue; }
  mine=$(printf '%s\n' "${repos[@]}" | awk -F/ -v o="$owner" 'tolower($1) == tolower(o)' | jq -Rnc '[inputs]')
  jq -n --argjson repos "$mine" --argjson consumers "$consumers" --argjson pkgs "$lib_packages" --arg dry "${DRY_RUN:-}" --arg bot "$BOT" --arg author "$BOT <$BOT_ID+$BOT@users.noreply.github.com>" '{
    platform: "github",
    username: $bot,
    gitAuthor: $author,
    onboarding: false,
    requireConfig: "required",
    repositories: $repos,
    cloneSubmodules: true,
    npmrc: "allow-git=all\n",
    npmrcMerge: true,
    packageRules: (if ($consumers | length) == 0 then [] else [{
      description: "lib rule 1: a lib consumer keeps every package lib names at lib'"'"'s exact version; the inbox job bump-lib moves them.",
      matchRepositories: $consumers, matchPackageNames: $pkgs, enabled: false }] end)
  } + (if $dry == "" then {} else {dryRun: $dry} end)' > "$OUT/renovate-$owner.json"
  owners=$(jq -c --arg o "$owner" '. + [$o]' <<<"$owners")
  echo "- $owner: $(jq -r 'join(", ")' <<<"$mine")"
done
echo "$owners" > "$OUT/owners.json"
