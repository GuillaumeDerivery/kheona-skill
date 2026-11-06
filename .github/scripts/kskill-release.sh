# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# the git side of the release PR (actions/kskill-release-pr and actions/kskill-ship). Reads refs only, never the
# worktree, and never pushes: the action pushes what this prints.
#
# Usage, from a full clone (fetch-depth 0) whose origin/main and origin/prod are fetched:
#   bash kskill-release.sh prepare <out-dir>   what the release PR is: writes <out-dir>/{status,reason,mode,head,
#                                              title,body.md} (+ message in squash mode) and the same keys
#                                              (status, reason, mode, head) to $GITHUB_OUTPUT when set.
#                                              status: skip (this repository does not release here), none
#                                              (nothing to release), open (head is the release PR's head).
#   bash kskill-release.sh verify <sha>        exit 0 only when pushing <sha> to prod is a fast-forward that
#                                              ships exactly what main holds (the ship guard).
# Env: KSKILL_MAIN (default origin/main), KSKILL_PROD (default origin/prod), GITHUB_REPOSITORY,
#      KSKILL_FORK (true in a fork).
#
# The release PR's head is a commit `prod` can fast-forward to, always:
#   - fast-forward mode (default): main's own commit; refused when prod holds a commit main lacks.
#   - squash mode (`workflows.release.squash: true`, a prod with no recent merge base with main): one new commit,
#     parent prod, tree = main's tree, message in ci-cd.md "The release commit" format, ending
#     `Squash of origin/main at <sha>`. Author, committer and dates are fixed (main's commit date), so the
#     same main and prod always give the same SHA and a re-run does not move the PR.
set -euo pipefail

MAIN=${KSKILL_MAIN:-origin/main}
PROD=${KSKILL_PROD:-origin/prod}
REPOSITORY=${GITHUB_REPOSITORY:-}
FORK=${KSKILL_FORK:-false}
MAX_LINES=150
BOT_NAME='github-actions[bot]'
BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
US=$'\x1f' # field separator of the change lines: never in a commit subject, and not whitespace (empty fields stay)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

die() { echo "::error::$1" >&2; exit 1; }
# A value of main's .kheona.json; empty when absent. Not `// empty`: jq's `//` treats false as missing.
cfg() { git show "$MAIN:.kheona.json" 2>/dev/null | jq -r "$1 | if . == null then empty else . end" 2>/dev/null || true; }
has() { git cat-file -e "$1" 2>/dev/null; }
short() { git rev-parse --short=7 "$1"; }

# Why this repository does not release through this workflow; empty when it does.
skip_reason() {
  has "$MAIN:.kheona.json" || { echo "main has no .kheona.json"; return; }
  git show "$MAIN:.kheona.json" | jq empty 2>/dev/null || die ".kheona.json on main is not valid JSON."
  local role enabled cd prod template
  role=$(cfg .role); enabled=$(cfg .workflows.release.enabled); cd=$(cfg .workflows.cd.enabled)
  prod=$(cfg .workflows.cd.prod); template=$(cfg .workflows.cd.templateRepository)
  if [ "$enabled" = false ]; then echo "workflows.release.enabled is false"
  elif [ "$cd" = false ]; then echo "workflows.cd.enabled is false: nothing is delivered from this repository"
  elif [ "$role" = library ]; then echo "role is library: a library is never deployed"
  elif [ -n "$template" ] && [ "$template" = "$REPOSITORY" ]; then echo "$REPOSITORY is a template (workflows.cd.templateRepository)"
  elif [ "$role" = template ] && [ "$FORK" != true ]; then echo "role is template: a template never deploys itself"
  elif [ "$prod" = false ]; then echo "workflows.cd.prod is false: this repository has no production"
  elif ! git rev-parse -q --verify "$PROD^{commit}" >/dev/null; then echo "there is no prod branch yet: the first release is 'git push origin origin/main:prod', by hand"
  fi
}

squash_mode() {
  local v; v=$(cfg .workflows.release.squash)
  case "${v:-false}" in true|false) echo "${v:-false}" ;; *) die "workflows.release.squash must be true or false, got '$v'." ;; esac
}

# The main commit a squash release commit names on its `Squash of origin/main at <sha>` line.
squash_source() { git log -1 --format=%B "$1" | sed -nE 's/^Squash of origin\/main at ([0-9a-f]{7,40})[[:space:]]*$/\1/p' | tail -1; }

stack() {
  if has "$MAIN:pubspec.yaml"; then echo flutter
  elif has "$MAIN:package.json"; then echo node
  elif has "$MAIN:pyproject.toml" || has "$MAIN:Pipfile"; then echo python
  fi
}

version() {
  case "$(stack)" in
    flutter) git show "$MAIN:pubspec.yaml" | sed -nE 's/^version:[[:space:]]*["'\'']?([^+"'\''[:space:]]+).*/\1/p' | head -1 ;;
    node) git show "$MAIN:package.json" | jq -r '.version // empty' 2>/dev/null || true ;;
    python) has "$MAIN:pyproject.toml" && git show "$MAIN:pyproject.toml" | sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' | head -1 ;;
  esac
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

group_of() {
  case "$1" in feat) echo Features ;; fix) echo Fixes ;; deps) echo Dependencies ;; *) echo Other ;; esac
}

# What ships, grouped, for the PR body.
changes_markdown() {
  local file=$1 total group n=0
  total=$(wc -l < "$file" | tr -d ' ')
  for group in Features Fixes Dependencies Other; do
    local lines=""
    while IFS=$US read -r type scope bang desc pr sha; do
      [ "$(group_of "$type")" = "$group" ] || continue
      n=$((n + 1)); [ "$n" -le "$MAX_LINES" ] || continue
      local label="$desc"
      [ -z "$scope" ] || [ "$scope" = deps ] || label="**$scope**: $desc"
      [ -z "$bang" ] || label="**BREAKING** $label"
      lines+="- $label${pr:+ (#$pr)} $sha"$'\n'
    done < "$file"
    [ -z "$lines" ] || printf '#### %s\n\n%s\n' "$group" "$lines"
  done
  # shellcheck disable=SC2016 # why: backticks are Markdown here, not command substitution
  [ "$total" -le "$MAX_LINES" ] || printf '_... and %s more: `git log --first-parent` on the range above._\n\n' "$((total - MAX_LINES))"
}

headline() {
  local file=$1 out="" count=0 type
  for type in feat fix '*'; do
    while IFS=$US read -r t _ _ desc _ _; do
      [ "$count" -lt 2 ] || break
      # shellcheck disable=SC2254 # why: the type is a pattern on purpose ('*' = any type, after feat and fix)
      case "$t" in $type) ;; *) continue ;; esac
      case "$type:$t" in '*:feat'|'*:fix') continue ;; esac
      out="${out:+$out; }$desc"; count=$((count + 1))
    done < "$file"
  done
  [ "${#out}" -le 90 ] || out="${out:0:87}..."
  echo "${out:-no change since the last release}"
}

# ci-cd.md "The release commit": one bullet per area, PR numbers in parentheses, then the squash line.
release_message() {
  local file=$1 title=$2 main_sha=$3
  printf '%s\n\n' "$title"
  awk -F "$US" '
    function area(type, scope) {
      if (type == "deps") return "Deps"
      if (type == "docs") return "Docs"
      if (type == "ci") return "CI"
      if (type == "test") return "Tests"
      if (scope != "") return toupper(substr(scope, 1, 1)) substr(scope, 2)
      if (type == "feat" || type == "fix" || type == "perf" || type == "refactor") return "App"
      return "Chores"
    }
    {
      a = area($1, $2)
      if (!(a in text)) { order[++n] = a; text[a] = ""; prs[a] = "" }
      d = $4; if ($3 == "!") d = "BREAKING: " d
      text[a] = text[a] (text[a] == "" ? "" : "; ") d
      if ($5 != "") prs[a] = prs[a] (prs[a] == "" ? "" : ", ") "#" $5
    }
    END { for (i = 1; i <= n; i++) { a = order[i]; printf "- %s: %s.%s\n", a, text[a], (prs[a] == "" ? "" : " (" prs[a] ")") } }
  ' "$file"
  printf '\nSquash of origin/main at %s\n' "$(short "$main_sha")"
}

targets_markdown() {
  local build=$1 head=$2 json
  json=$(git show "$MAIN:.kheona.json")
  if [ "$(stack)" = flutter ]; then
    jq -r --arg b "$build" '.workflows.cd as $c
      | (if ($c.android.enabled // true) then "- **Google Play**: fastlane lane `\($c.android.lane // "beta")` in `android/`, build \($b)" else empty end),
        (if ($c.ios.enabled // true) then "- **TestFlight**: fastlane lane `\($c.ios.lane // "beta")` in `ios/`, build \($b)\(if ($c.ios.xcode // "") != "" then ", Xcode \($c.ios.xcode)" else "" end)" else empty end),
        "- Delivered by `Kheona Skill · Deliver` on the push to `prod`."' <<<"$json"
  else
    jq -r --arg s "$head" '.workflows.cd.prod as $p
      | if ($p | type) != "object" then "- `workflows.cd.prod` is not set: `Kheona Skill · CD · Build, push and deploy` will refuse the push."
        else
          "- **Image** `\($p.ecrRepository)`:`\($s)` (AWS `\($p.region)`), EKS cluster `\($p.cluster)`",
          (($p.targets // [{namespace: $p.namespace, deployments: $p.deployments, cronjobs: $p.cronjobs}])[]
            | "- Namespace `\(.namespace)`: \([((.deployments // [])[] | "deployment `\(.)`"), ((.cronjobs // [])[] | "cron job `\(.)`")] | join(", "))"),
          (if ($p.healthcheckUrl // "") != "" then "- Health check `\($p.healthcheckUrl)` must report commit `\($s)`" else empty end),
          "- Deployed by `Kheona Skill · CD · Build, push and deploy` on the push to `prod`."
        end' <<<"$json"
  fi
}

# What deserves a look before shipping, from the tree diff prod -> main and the commit messages. Cheap and
# heuristic: it names what it found and never claims a release is safe.
risks_markdown() {
  local changes_file=$1 names f old new added removed vars
  names=$(git diff --name-status --no-renames "$PROD" "$MAIN")
  out() { printf -- '- %s\n' "$1"; }
  if awk -F "$US" '$3 == "!" { found = 1 } END { exit !found }' "$changes_file"; then
    out "**Breaking change** announced in: $(awk -F "$US" '$3 == "!" { printf "%s%s", (n++ ? ", " : ""), ($5 != "" ? "#" $5 : $6) }' "$changes_file")."
  fi
  f=$(awk -F '\t' '$1 != "D" && $2 ~ /(^|\/)(migrations?|migrate)(\/|$)|[Mm]igration[^\/]*$/ { printf "%s`%s`", (n++ ? ", " : ""), $2 }' <<<"$names")
  [ -z "$f" ] || out "**Migrations**: $f. Run order and rollback?"
  while IFS=$'\t' read -r status path; do
    [ -n "$path" ] || continue
    case "$path" in config/*.json) ;; *) continue ;; esac
    old=$( { git show "$PROD:$path" 2>/dev/null || echo '{}'; } | jq -r '[paths(scalars) | map(tostring) | join(".")] | .[]' 2>/dev/null | sort -u || true)
    new=$( { git show "$MAIN:$path" 2>/dev/null || echo '{}'; } | jq -r '[paths(scalars) | map(tostring) | join(".")] | .[]' 2>/dev/null | sort -u || true)
    added=$(comm -13 <(echo "$old") <(echo "$new") | sed '/^$/d' | awk '{ printf "%s`%s`", (n++ ? ", " : ""), $0 }')
    removed=$(comm -23 <(echo "$old") <(echo "$new") | sed '/^$/d' | awk '{ printf "%s`%s`", (n++ ? ", " : ""), $0 }')
    [ -z "$added" ] || out "**Configuration keys added** in \`$path\`: $added. Set for production before shipping?"
    [ -z "$removed" ] || out "**Configuration keys removed** from \`$path\`: $removed."
    : "$status"
  done <<<"$names"
  f=$(awk -F '\t' '$2 ~ /(^|\/)\.env[^\/]*$|\.env\.(example|sample)$|^config\/[^\/]+\.(ya?ml|[cm]?[jt]s)$/ { printf "%s`%s`", (n++ ? ", " : ""), $2 }' <<<"$names")
  [ -z "$f" ] || out "**Configuration files changed**: $f."
  # Environment variables read by code that did not read them before.
  vars=$(git diff --no-renames "$PROD" "$MAIN" -- '*.ts' '*.js' '*.mjs' '*.cjs' '*.py' '*.dart' \
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
  git diff --raw --no-renames "$PROD" "$MAIN" | awk '$2 == "160000" || $1 ~ /160000/ { print $3 " " $4 " " $6 }' | while read -r a b p; do
    out "**Submodule** \`$p\` moves ${a:0:7} -> ${b:0:7}."
  done
  f=$(awk -F '\t' '$2 ~ /(^|\/)(package-lock\.json|pubspec\.lock|Pipfile\.lock|poetry\.lock|uv\.lock|yarn\.lock|pnpm-lock\.yaml)$/ { printf "%s`%s`", (n++ ? ", " : ""), $2 }' <<<"$names")
  [ -z "$f" ] || out "**Dependencies** change: $f."
  if [ "$(stack)" = flutter ] && has "$PROD:pubspec.yaml"; then
    local before after
    before=$(git show "$PROD:pubspec.yaml" | sed -nE 's/^version:[[:space:]]*["'\'']?([^+"'\''[:space:]]+).*/\1/p' | head -1)
    after=$(version)
    [ "$before" != "$after" ] || out "**Version name** stays \`$after\` (only the build number moves)."
  fi
}

prepare() {
  local outdir=${1:?usage: kskill-release.sh prepare <out-dir>} reason mode main_sha prod_sha base="" note="" head title build="" ver offset
  mkdir -p "$outdir"
  emit() { # emit <key> <value>: a one-line result, in the out dir and in GITHUB_OUTPUT
    printf '%s\n' "$2" > "$outdir/$1"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi
  }
  reason=$(skip_reason)
  if [ -n "$reason" ]; then emit status skip; emit reason "$reason"; echo "Skipped: $reason."; return 0; fi
  main_sha=$(git rev-parse "$MAIN^{commit}"); prod_sha=$(git rev-parse "$PROD^{commit}")
  mode=fast-forward; [ "$(squash_mode)" = false ] || mode=squash
  emit mode "$mode"

  if [ "$mode" = fast-forward ]; then
    if [ "$main_sha" = "$prod_sha" ]; then emit status none; emit reason "prod is main ($(short "$main_sha"))"; echo "Nothing to release."; return 0; fi
    if ! git merge-base --is-ancestor "$prod_sha" "$main_sha"; then
      die "prod holds $(git rev-list --count "$main_sha..$prod_sha") commit(s) main lacks: it cannot fast-forward to main. A repository that releases by squashing main onto prod sets workflows.release.squash to true; otherwise bring those commits to main."
    fi
    base=$prod_sha; head=$main_sha
  else
    local src; src=$(squash_source "$prod_sha")
    if [ "$(git rev-parse "$prod_sha^{tree}")" = "$(git rev-parse "$main_sha^{tree}")" ]; then
      emit status none; emit reason "prod already holds main's tree ($(short "$main_sha"))"; echo "Nothing to release."; return 0
    fi
    if [ -n "$src" ] && git rev-parse -q --verify "$src^{commit}" >/dev/null && git merge-base --is-ancestor "$src" "$main_sha"; then
      base=$(git rev-parse "$src^{commit}")
    else
      base=$(git merge-base "$prod_sha" "$main_sha" || true)
      note="The last release commit on prod has no usable \`Squash of origin/main at <sha>\` line: the list below starts at ${base:+the merge base $(short "$base")}${base:-the first commit}. Check it against the previous release."
    fi
  fi

  local work=$WORK
  if [ -n "$base" ]; then changes "$base..$main_sha" > "$work/changes"; else changes "$main_sha" > "$work/changes"; fi

  ver=$(version)
  if [ "$(stack)" = flutter ]; then
    offset=$(cfg .workflows.cd.buildNumber.offset); offset=${offset:-0}
    [[ $offset =~ ^[0-9]+$ ]] || die "workflows.cd.buildNumber.offset must be a non-negative integer, got '$offset'."
    if [ "$mode" = squash ]; then build=$(( $(git rev-list --count "$prod_sha") + 1 + offset )); else build=$(( $(git rev-list --count "$main_sha") + offset )); fi
    title="Release ${ver:-?} ($build) — $(headline "$work/changes")"
  else
    title="Release ${ver:+$ver }$(short "$main_sha") — $(headline "$work/changes")"
  fi

  if [ "$mode" = squash ]; then
    release_message "$work/changes" "$title" "$main_sha" > "$outdir/message"
    local date; date=$(git log -1 --format=%cI "$main_sha")
    head=$(GIT_AUTHOR_NAME=$BOT_NAME GIT_AUTHOR_EMAIL=$BOT_EMAIL GIT_COMMITTER_NAME=$BOT_NAME GIT_COMMITTER_EMAIL=$BOT_EMAIL \
      GIT_AUTHOR_DATE=$date GIT_COMMITTER_DATE=$date git commit-tree "$main_sha^{tree}" -p "$prod_sha" -F "$outdir/message")
  fi
  emit status open; emit head "$head"; emit reason "$(wc -l < "$work/changes" | tr -d ' ') change(s)"
  printf '%s\n' "$title" > "$outdir/title"

  local risks; risks=$(risks_markdown "$work/changes")
  {
    echo '<!-- kskill-release: written by the release-pr job (Kheona Skill · Main, Ship, Inbox); edits are overwritten on the next run -->'
    if [ "$mode" = squash ]; then
      echo "Ships \`main\` at $(short "$main_sha") to \`prod\` as one release commit $(short "$head") on top of $(short "$prod_sha") (squash mode)."
    else
      echo "Ships \`main\` at $(short "$main_sha") to \`prod\` (now $(short "$prod_sha")) by fast-forward: $(git rev-list --count "$prod_sha..$main_sha") commit(s)."
    fi
    echo
    echo '### What ships'
    echo
    [ -z "$note" ] || { echo "> $note"; echo; }
    if [ -s "$work/changes" ]; then changes_markdown "$work/changes"; else echo '_No commit on main since the last release: a re-ship of the same tree._'; echo; fi
    echo '### Where it goes'
    echo
    targets_markdown "$build" "$head"
    echo
    echo '### Check before shipping'
    echo
    if [ -n "$risks" ]; then echo "$risks"; else echo '- Nothing detected: no migration, configuration key, new environment variable, native setting, pipeline, submodule or lockfile change.'; fi
    echo
    echo '_Detected from file names and diffs: a hint list, not a review._'
    echo
    if [ "$mode" = squash ]; then
      echo '<details><summary>Release commit (what <code>git log origin/prod</code> will show)</summary>'
      echo; echo '```text'; cat "$outdir/message"; echo '```'; echo; echo '</details>'; echo
    fi
    echo '### How to ship'
    echo
    echo "Add the label \`ship\` to this PR. \`Kheona Skill · CD · Push to prod and deploy\` then checks that you have write access and that the head is still $(short "$head"), and pushes that exact commit to \`prod\` without force: a fast-forward, as requires. The push starts the deploy; this PR then shows as merged."
    echo
    # shellcheck disable=SC2016 # why: backticks are Markdown here, not command substitution
    echo 'Do not press Merge (this PR stays a draft for that reason): every merge method writes onto `prod` a commit other than the one reviewed here (a merge commit, a squash, rebased copies), and in fast-forward mode leaves `prod` holding a commit `main` lacks, so it can never fast-forward again. Not ready? Do nothing: this PR follows `main` until someone ships it.'
  } > "$outdir/body.md"
  echo "$title"
}

verify() {
  local sha=${1:?usage: kskill-release.sh verify <sha>} reason main_sha prod_sha src
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "'$sha' is not a full commit SHA."
  git rev-parse -q --verify "$sha^{commit}" >/dev/null || die "$sha is not in this clone."
  reason=$(skip_reason)
  [ -z "$reason" ] || die "this repository does not release through this workflow: $reason."
  main_sha=$(git rev-parse "$MAIN^{commit}"); prod_sha=$(git rev-parse "$PROD^{commit}")
  [ "$sha" != "$prod_sha" ] || die "prod is already at $sha."
  git merge-base --is-ancestor "$prod_sha" "$sha" || die "$sha does not descend from prod ($(short "$prod_sha")): pushing it would not be a fast-forward."
  if [ "$(squash_mode)" = false ]; then
    git merge-base --is-ancestor "$sha" "$main_sha" || die "$sha is not on main: only what main holds ships."
  else
    [ "$(git rev-parse "$sha^@")" = "$prod_sha" ] || die "$sha is not one commit on top of prod: a squash release is exactly one commit."
    src=$(squash_source "$sha")
    [ -n "$src" ] || die "$sha has no 'Squash of origin/main at <sha>' line."
    if ! git rev-parse -q --verify "$src^{commit}" >/dev/null || ! git merge-base --is-ancestor "$src" "$main_sha"; then
      die "$sha names main at $src, which is not on main."
    fi
    [ "$(git rev-parse "$sha^{tree}")" = "$(git rev-parse "$src^{tree}")" ] || die "$sha does not hold main's tree at $src."
  fi
  echo "OK: prod $(short "$prod_sha") -> $(short "$sha") is a fast-forward and ships what main holds."
}

case "${1:-}" in
  prepare) shift; prepare "$@" ;;
  verify) shift; verify "$@" ;;
  *) echo "usage: kskill-release.sh prepare <out-dir> | verify <sha>" >&2; exit 64 ;;
esac
