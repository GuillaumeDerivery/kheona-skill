# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# The "Check before you merge" section of release-please's PR, outside a library: where the release goes and what
# deserves a look (migrations, configuration keys, environment variables, native settings, pipeline, submodules,
# lockfiles), from the diff between the last version tag and main. Run by kskill-release-please.yml after each update
# of the PR, which puts it between markers at the end of the PR body (release-please rewrites the rest). Reads refs
# only, never the worktree, never pushes.
#
# Usage, from a full clone (fetch-depth 0, tags fetched): bash kskill-release.sh notes
#   prints the section, or nothing where this repository releases nothing to production (a library, a template,
#   workflows.cd.enabled or .prod false).
# Env: KSKILL_MAIN (default origin/main), GITHUB_REPOSITORY, KSKILL_FORK (true in a fork).
set -euo pipefail

MAIN=${KSKILL_MAIN:-origin/main}
REPOSITORY=${GITHUB_REPOSITORY:-}
FORK=${KSKILL_FORK:-false}
US=$'\x1f' # field separator of the change lines: never in a commit subject, and not whitespace (empty fields stay)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

die() { echo "::error::$1" >&2; exit 1; }
# A value of main's .kheona.json; empty when absent. Not `// empty`: jq's `//` treats false as missing.
cfg() { git show "$MAIN:.kheona.json" 2>/dev/null | jq -r "$1 | if . == null then empty else . end" 2>/dev/null || true; }
has() { git cat-file -e "$1" 2>/dev/null; }
short() { git rev-parse --short=7 "$1"; }

# Why this repository releases nothing to production; empty when it does.
skip_reason() {
  has "$MAIN:.kheona.json" || { echo "main has no .kheona.json"; return; }
  git show "$MAIN:.kheona.json" | jq empty 2>/dev/null || die ".kheona.json on main is not valid JSON."
  local role cd prod template
  role=$(cfg .role); cd=$(cfg .workflows.cd.enabled)
  prod=$(cfg .workflows.cd.prod); template=$(cfg .workflows.cd.templateRepository)
  if [ "$cd" = false ]; then echo "workflows.cd.enabled is false"
  elif [ "$role" = library ]; then echo "role is library"
  elif [ -n "$template" ] && [ "$template" = "$REPOSITORY" ]; then echo "$REPOSITORY is a template"
  elif [ "$role" = template ] && [ "$FORK" != true ]; then echo "role is template"
  elif [ "$prod" = false ]; then echo "workflows.cd.prod is false"
  fi
}

stack() {
  if has "$MAIN:pubspec.yaml"; then echo flutter
  elif has "$MAIN:package.json"; then echo node
  elif has "$MAIN:pyproject.toml" || has "$MAIN:Pipfile"; then echo python
  fi
}


# One line per change: type, scope, breaking (!), description, PR number, short SHA, separated by $US. First-parent: a squash-merged
# PR is one commit, a merge commit stands for its PR (its subject is then the PR title, from the body).
changes() {
  local range=$1 sha subject body re='^([A-Za-z]+)(\(([^)]*)\))?(!)?:[[:space:]]*(.*)$' pr_re='^(.*[^[:space:]])[[:space:]]*\(#([0-9]+)\)$'
  local merge_re='^Merge pull request #([0-9]+) '
  git log --reverse --first-parent --format='%H%x09%s' "$range" | while IFS=$'\t' read -r sha subject; do
    local type="" scope="" bang="" desc="$subject" pr=""
    if [[ $subject =~ $merge_re ]]; then
      pr=${BASH_REMATCH[1]}
      body=$(git log -1 --format=%b "$sha" | sed -n '/[^[:space:]]/{p;q;}')
      desc=${body:-$subject}; subject="$desc"
    fi
    if [[ $subject =~ $re ]]; then
      type=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]'); scope=${BASH_REMATCH[3]}; bang=${BASH_REMATCH[4]}; desc=${BASH_REMATCH[5]}
    fi
    if [[ $desc =~ $pr_re ]]; then desc=${BASH_REMATCH[1]}; pr=${BASH_REMATCH[2]}; fi
    if [ -z "$bang" ] && git log -1 --format=%b "$sha" | grep -q '^BREAKING[ -]CHANGE'; then bang='!'; fi
    if [ "$scope" = deps ] || [ "$type" = deps ] || [[ $desc =~ ^[Bb]ump\  ]]; then type=deps; fi
    printf '%s\n' "${type:-other}$US$scope$US$bang$US$desc$US$pr$US${sha:0:7}"
  done
}

targets_markdown() {
  local build=$1 head=$2 json
  json=$(git show "$MAIN:.kheona.json")
  if [ "$(stack)" = flutter ]; then
    jq -r --arg b "$build" '.workflows.cd as $c
      | (if ($c.android.enabled // true) then "- **Google Play**: fastlane lane `\($c.android.lane // "beta")` in `android/`, build \($b)" else empty end),
        (if ($c.ios.enabled // true) then "- **TestFlight**: fastlane lane `\($c.ios.lane // "beta")` in `ios/`, build \($b)\(if ($c.ios.xcode // "") != "" then ", Xcode \($c.ios.xcode)" else "" end)" else empty end),
        "- Delivered by `Kheona Skill · Deliver` when the version tag is pushed."' <<<"$json"
  else
    jq -r --arg s "$head" '.workflows.cd as $c | .workflows.cd.prod as $p
      | if ($p | type) != "object" then "- `workflows.cd.prod` is not set: the version tag deploys nothing."
        else
          (if ($c.target // "eks") == "custom" then "- Deployed by the repository workflow (`workflows.cd.target` custom), after the checks and the gate." else
          "- **Image** `\($p.ecrRepository)` (AWS `\($p.region)`), EKS cluster `\($p.cluster)`, by digest" end),
          (($p.targets // [{namespace: $p.namespace, deployments: $p.deployments, cronjobs: $p.cronjobs}])[]
            | "- Namespace `\(.namespace)`: \([((.deployments // [])[] | "deployment `\(.)`"), ((.cronjobs // [])[] | "cron job `\(.)`")] | join(", "))"),
          (if ($p.healthcheckUrl // "") != "" then "- Health check `\($p.healthcheckUrl)` must report commit `\($s)`" else empty end),
          "- Deployed by `Kheona Skill · CD · Build, push and deploy` when the version tag is pushed, after the release checks and the full gate."
        end' <<<"$json"
  fi
}

# What deserves a look before releasing, from the tree diff last release -> main and the commit messages. Cheap and
# heuristic: it names what it found and never claims a release is safe.
risks_markdown() {
  local changes_file=$1 names f old new added removed vars
  names=$(git diff --name-status --no-renames "$BASE" "$MAIN")
  out() { printf -- '- %s\n' "$1"; }
  if awk -F "$US" '$3 == "!" { found = 1 } END { exit !found }' "$changes_file"; then
    out "**Breaking change** announced in: $(awk -F "$US" '$3 == "!" { printf "%s%s", (n++ ? ", " : ""), ($5 != "" ? "#" $5 : $6) }' "$changes_file")."
  fi
  f=$(awk -F '\t' '$1 != "D" && $2 ~ /(^|\/)(migrations?|migrate)(\/|$)|[Mm]igration[^\/]*$/ { printf "%s`%s`", (n++ ? ", " : ""), $2 }' <<<"$names")
  [ -z "$f" ] || out "**Migrations**: $f. Run order and rollback?"
  while IFS=$'\t' read -r status path; do
    [ -n "$path" ] || continue
    case "$path" in config/*.json) ;; *) continue ;; esac
    old=$( { git show "$BASE:$path" 2>/dev/null || echo '{}'; } | jq -r '[paths(scalars) | map(tostring) | join(".")] | .[]' 2>/dev/null | sort -u || true)
    new=$( { git show "$MAIN:$path" 2>/dev/null || echo '{}'; } | jq -r '[paths(scalars) | map(tostring) | join(".")] | .[]' 2>/dev/null | sort -u || true)
    added=$(comm -13 <(echo "$old") <(echo "$new") | sed '/^$/d' | awk '{ printf "%s`%s`", (n++ ? ", " : ""), $0 }')
    removed=$(comm -23 <(echo "$old") <(echo "$new") | sed '/^$/d' | awk '{ printf "%s`%s`", (n++ ? ", " : ""), $0 }')
    [ -z "$added" ] || out "**Configuration keys added** in \`$path\`: $added. Set for production before merging?"
    [ -z "$removed" ] || out "**Configuration keys removed** from \`$path\`: $removed."
    : "$status"
  done <<<"$names"
  f=$(awk -F '\t' '$2 ~ /(^|\/)\.env[^\/]*$|\.env\.(example|sample)$|^config\/[^\/]+\.(ya?ml|[cm]?[jt]s)$/ { printf "%s`%s`", (n++ ? ", " : ""), $2 }' <<<"$names")
  [ -z "$f" ] || out "**Configuration files changed**: $f."
  # Environment variables read by code that did not read them before.
  vars=$(git diff --no-renames "$BASE" "$MAIN" -- '*.ts' '*.js' '*.mjs' '*.cjs' '*.py' '*.dart' \
    | awk '/^\+[^+]/ { print "+" substr($0, 2) } /^-[^-]/ { print "-" substr($0, 2) }' \
    | sed -nE 's/^([+-]).*(process\.env\.|process\.env\[["'\'']|os\.environ\[["'\'']|os\.environ\.get\(["'\'']|getenv\(["'\'']|fromEnvironment\(["'\''])([A-Za-z_][A-Za-z0-9_]*).*/\1\3/p' | sort -u)
  added=$(comm -23 <(grep '^+' <<<"$vars" | cut -c2- | sort -u) <(grep '^-' <<<"$vars" | cut -c2- | sort -u) | sed '/^$/d' | awk '{ printf "%s`%s`", (n++ ? ", " : ""), $0 }')
  [ -z "$added" ] || out "**Environment variables newly read**: $added. Set in production?"
  f=$(awk -F '\t' '$2 ~ /(^|\/)Info\.plist$|AndroidManifest\.xml$|\.entitlements$|^android\/app\/build\.gradle(\.kts)?$/ { printf "%s`%s`", (n++ ? ", " : ""), $2 }' <<<"$names")
  [ -z "$f" ] || out "**Native app settings** (permissions, entitlements, SDK levels): $f. Store review?"
  f=$(awk -F '\t' '$2 ~ /^\.github\/(workflows|actions|scripts)\// { printf "%s`%s`", (n++ ? ", " : ""), $2 }' <<<"$names")
  [ -z "$f" ] || out "**Pipeline** changes ship with this release: $f."
  f=$(awk -F '\t' '$2 ~ /(^|\/)Dockerfile[^\/]*$|^(k8s|kubernetes|helm|deploy|infra|terraform)\// { printf "%s`%s`", (n++ ? ", " : ""), $2 }' <<<"$names")
  [ -z "$f" ] || out "**Image or infrastructure**: $f."
  git diff --raw --no-renames "$BASE" "$MAIN" | awk '$2 == "160000" || $1 ~ /160000/ { print $3 " " $4 " " $6 }' | while read -r a b p; do
    out "**Submodule** \`$p\` moves ${a:0:7} -> ${b:0:7}."
  done
  f=$(awk -F '\t' '$2 ~ /(^|\/)(package-lock\.json|pubspec\.lock|Pipfile\.lock|poetry\.lock|uv\.lock|yarn\.lock|pnpm-lock\.yaml)$/ { printf "%s`%s`", (n++ ? ", " : ""), $2 }' <<<"$names")
  [ -z "$f" ] || out "**Dependencies** change: $f."
}

notes() {
  local reason risks
  reason=$(skip_reason)
  if [ -n "$reason" ]; then echo "No release notes: $reason." >&2; return 0; fi
  BASE=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' "$MAIN" 2>/dev/null || true)
  BASE_SET=$BASE
  # No release yet: everything on main is new (the empty tree as the base).
  [ -n "$BASE" ] || BASE=$(git hash-object -t tree /dev/null)
  if [ -n "$BASE_SET" ]; then changes "$BASE..$MAIN" > "$WORK/changes"; else changes "$MAIN" > "$WORK/changes"; fi
  risks=$(risks_markdown "$WORK/changes")
  echo '<!-- kskill-release-notes:start -->'
  echo '### Check before you merge'
  echo
  echo "Merging this PR tags the version, and the tag releases to production. Since ${BASE_SET:-the first commit}: $(wc -l < "$WORK/changes" | tr -d ' ') change(s), main at $(short "$MAIN")."
  echo
  echo '#### Where it goes'
  echo
  targets_markdown "" "$(git rev-parse "$MAIN")"
  echo
  echo '#### Look at'
  echo
  if [ -n "$risks" ]; then echo "$risks"; else echo '- Nothing detected: no migration, configuration key, new environment variable, native setting, pipeline, submodule or lockfile change.'; fi
  echo
  echo '_Detected from file names and diffs: a hint list, not a review. Rewritten by Kheona Skill · Release on every update of this PR._'
  echo '<!-- kskill-release-notes:end -->'
}

case "${1:-}" in
  notes) notes ;;
  *) echo "usage: kskill-release.sh notes" >&2; exit 64 ;;
esac
