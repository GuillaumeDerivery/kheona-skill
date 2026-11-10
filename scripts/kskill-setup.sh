#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck disable=SC2016  # why: the single-quoted strings are jq programs; their $names are jq variables
# The setup command: brings one repository onto this version of kheona-skill, and says what is left. Safe to re-run:
# every step checks first, and a step already done says so. Without --apply it changes nothing.
#
# Usage: kskill-setup.sh [--apply] <owner/repo> <clone>
#   <clone>  a local clone of the repository, on its default branch, clean.
#   --apply  writes what is missing in the clone (.kheona.json, release files, callers, the Renovate preset) and opens
#            one PR with it (its CI is the proof); applies the repository settings and topic; sets the variables it
#            can; in a terminal, asks for each missing secret, one at a time.
# Env: KSKILL_BOT (the App's <app-slug>[bot]) and KSKILL_TOKEN_BROKER_URL (its broker): set as variables when missing.
# Steps: 1 .kheona.json, 2 topic, 3 release files, 4 callers and Renovate preset, 5 settings, 6 variables,
#        7 secrets (the store secrets walked through one by one), 8 the repository check, 9 the PR that proves it.
# Prints one line per step: "ok", "done" (with --apply), "todo" (left to do: what and how). Exit 1 when a todo is left.
# A secret's value is read from the terminal without echo, or from a file a person names, handed to `gh secret set`
# on its standard input, and never printed, logged or written to disk.
set -uo pipefail

APPLY=false
if [ "${1:-}" = --apply ]; then APPLY=true; shift; fi
REPO=${1:?usage: kskill-setup.sh [--apply] <owner/repo> <clone>}
DIR=${2:?usage: kskill-setup.sh [--apply] <owner/repo> <clone>}
DIR=$(cd "$DIR" && pwd) || exit 64
SKILL=$(cd "$(dirname "$0")/.." && pwd)
SELF=${KSKILL_SELF:-$(git -C "$SKILL" remote get-url origin 2>/dev/null | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')}
VERSION=${KSKILL_VERSION:-$(git -C "$SKILL" describe --tags --exact-match 2>/dev/null || true)}
SHA=${KSKILL_SHA:-$(git -C "$SKILL" rev-parse HEAD)}
TODO=0
ok() { printf 'ok    %s\n' "$1"; }
did() { printf 'done  %s\n' "$1"; }
todo() { printf 'todo  %s\n' "$1"; TODO=1; }
cfg() { jq -r "$1 // empty" "$DIR/.kheona.json" 2>/dev/null; }
stack() {
  if [ -f "$DIR/pubspec.yaml" ]; then echo flutter; elif [ -f "$DIR/package.json" ]; then echo node
  elif [ -f "$DIR/pyproject.toml" ] || [ -f "$DIR/Pipfile" ]; then echo python; elif ls "$DIR"/*.tf "$DIR"/terraform >/dev/null 2>&1; then echo infra; fi
}

[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "This checkout of kheona-skill is not at a version tag (KSKILL_VERSION): check out a release first." >&2; exit 64; }
echo "Setting up $REPO at $SELF $VERSION$($APPLY || echo ', check only')."

# 1. .kheona.json: the repository's one configuration. A new one says project; a person adds the deploy's targets.
if [ -f "$DIR/.kheona.json" ] && jq empty "$DIR/.kheona.json" 2>/dev/null; then ok ".kheona.json ($(cfg .role))"
elif [ -f "$DIR/.kheona.json" ]; then todo ".kheona.json is not valid JSON: fix it, then run this again"
elif $APPLY; then echo '{"role": "project"}' > "$DIR/.kheona.json"; did ".kheona.json written as a project: add workflows.cd for a deploy (docs/kheona-json.md)"
else todo ".kheona.json missing: --apply writes {\"role\": \"project\"}"; fi
ROLE=$(cfg .role); STACK=$(stack)

# 2. The topic the automation finds repositories by.
topics=$(gh api "repos/$REPO/topics" --jq '.names | join(" ")' 2>/dev/null || echo '?')
if [[ " $topics " == *" kheona-skill "* || " $topics " == *" kskill "* ]]; then ok "topic"
elif [ "$topics" = '?' ]; then todo "topics unreadable: does this login have admin on $REPO?"
elif $APPLY && gh api -X PUT "repos/$REPO/topics" --input <(jq -nc --arg t "$topics" '{names: (($t | split(" ") | map(select(. != ""))) + ["kheona-skill"])}') > /dev/null; then did "topic kheona-skill"
else todo "topic kheona-skill: --apply adds it"; fi

# 3. Release files, where a version tag ships something: a manifest seeded at the current version, on several lines
# (release-please keeps that indent; a one-line manifest comes back compact and fails Prettier).
ships=true
[ "$ROLE" = library ] || [ "$ROLE" = template ] || [ "$(cfg .workflows.cd.enabled)" = false ] && ships=false
[ "$ROLE" = library ] && ships=true  # a library releases too: its tag notifies its consumers
if ! $ships; then ok "release files (nothing releases here)"
elif [ -f "$DIR/release-please-config.json" ] && [ -f "$DIR/.release-please-manifest.json" ]; then ok "release files"
elif $APPLY; then
  case "$STACK" in node) type=node; v=$(jq -r '.version // empty' "$DIR/package.json") ;;
    flutter) type=dart; v=$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$DIR/pubspec.yaml") ;;
    python) type=python; v=$(sed -nE 's/^version[[:space:]]*=[[:space:]]*"([0-9.]+)".*/\1/p' "$DIR/pyproject.toml" 2>/dev/null) ;;
    *) type=simple; v= ;; esac
  [ -f "$DIR/release-please-config.json" ] || jq -n --arg t "$type" '{packages: {".": {"release-type": $t}}}' > "$DIR/release-please-config.json"
  [ -f "$DIR/.release-please-manifest.json" ] || printf '{\n  ".": "%s"\n}\n' "${v:-0.1.0}" > "$DIR/.release-please-manifest.json"
  did "release files (release-type $type, from ${v:-0.1.0})"
else todo "release files missing: --apply writes release-please-config.json and the manifest"; fi

# 4. The callers and the Renovate preset, exactly what this version writes.
if node "$SKILL/scripts/kskill-callers.mjs" check --repo "$DIR" > /dev/null 2>&1 && grep -q "renovate/default#$VERSION" "$DIR/renovate.json" 2>/dev/null; then ok "callers at $VERSION"
elif $APPLY; then
  [ -f "$DIR/renovate.json" ] || jq -n --arg s "$SELF" --arg v "$VERSION" '{"$schema": "https://docs.renovatebot.com/renovate-schema.json", extends: ["github>\($s)//renovate/default#\($v)"]}' > "$DIR/renovate.json"
  node "$SKILL/scripts/kskill-callers.mjs" write --repo "$DIR" --self "$SELF" --sha "$SHA" --version "$VERSION" > /dev/null && did "callers and the Renovate preset at $VERSION"
else todo "callers: --apply writes them at $VERSION"; fi

# 5. Repository settings (squash merges, workflow permissions, the KSKILL_* variables the configuration implies).
settings=(bash "$SKILL/scripts/kskill-repo-settings.sh" "$REPO")
if [ -z "${KSKILL_BOT:-}" ]; then todo "settings: KSKILL_BOT (your App's <app-slug>[bot]) is needed to check them"
elif "${settings[@]}" > /dev/null 2>&1; then ok "settings"
elif $APPLY && "${settings[@]}" --apply > /dev/null 2>&1; then did "settings"
else todo "settings drift: KSKILL_BOT=$KSKILL_BOT ${settings[*]} shows it; --apply sets them"; fi

# 6. Variables: the broker every shared workflow asks for its token.
vars=$(gh api "repos/$REPO/actions/variables?per_page=100" --jq '[.variables[].name] | join(" ")' 2>/dev/null || echo '?')
if [[ " $vars " == *" KSKILL_TOKEN_BROKER_URL "* ]]; then ok "variable KSKILL_TOKEN_BROKER_URL"
elif $APPLY && [ -n "${KSKILL_TOKEN_BROKER_URL:-}" ] && gh variable set KSKILL_TOKEN_BROKER_URL --repo "$REPO" --body "$KSKILL_TOKEN_BROKER_URL" > /dev/null; then did "variable KSKILL_TOKEN_BROKER_URL"
else todo "variable KSKILL_TOKEN_BROKER_URL: set KSKILL_TOKEN_BROKER_URL and --apply, or gh variable set KSKILL_TOKEN_BROKER_URL --repo $REPO"; fi

# 7. Secrets, names only: the ones a workflow here fails without. A store secret is walked through with --apply in a
# terminal: what it is, where it comes from, then its value (hidden) or a file to encode.
have=$(gh secret list --repo "$REPO" --json name --jq '[.[].name] | join(" ")' 2>/dev/null || echo '?')
need=()
if [ -f "$DIR/.github/workflows/kskill-deliver.yml" ] && [ "$(cfg .workflows.cd.enabled)" != false ]; then
  [ "$(cfg .workflows.cd.android.enabled)" = false ] || need+=(ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD PLAY_STORE_JSON_KEY_BASE64)
  [ "$(cfg .workflows.cd.ios.enabled)" = false ] || need+=(IOS_DIST_CERTIFICATE_P12_BASE64 IOS_DIST_CERTIFICATE_PASSWORD ASC_KEY_ID ASC_ISSUER_ID ASC_API_KEY_BASE64)
fi
if [ -f "$DIR/.github/workflows/kskill-deploy.yml" ]; then
  for env in staging prod; do
    t=$(jq -r --arg e "$env" '.workflows.cd[$e] | type' "$DIR/.kheona.json" 2>/dev/null)
    [ "$t" = object ] && [ -z "$(cfg ".workflows.cd.$env.awsRoleArn")" ] && need+=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY)
  done
fi
# the Codemagic-era name of a signing secret, still accepted by the delivery: the new one takes the same value.
old() { [[ " $have " != *" $1 "* ]] || echo " (the same value as $1, its old name, deleted once this one is set)"; }
hint() {
  case $1 in
    ANDROID_KEYSTORE_BASE64) echo "the Android upload keystore (.jks), a file: it is base64-encoded for you" ;;
    ANDROID_KEYSTORE_PASSWORD) echo "the keystore's password$(old CM_KEYSTORE_PASSWORD)" ;;
    ANDROID_KEY_ALIAS) echo "the upload key's alias in the keystore$(old CM_KEY_ALIAS)" ;;
    ANDROID_KEY_PASSWORD) echo "the upload key's password$(old CM_KEY_PASSWORD)" ;;
    PLAY_STORE_JSON_KEY_BASE64) echo "a Google Play service account's JSON key with release rights on the app, a file" ;;
    IOS_DIST_CERTIFICATE_P12_BASE64) echo "an Apple Distribution certificate and its private key exported as .p12, a file" ;;
    IOS_DIST_CERTIFICATE_PASSWORD) echo "the .p12's password" ;;
    ASC_KEY_ID) echo "the App Store Connect API key's id (App Manager role, never Admin)" ;;
    ASC_ISSUER_ID) echo "the App Store Connect issuer id (Users and Access, Integrations)" ;;
    ASC_API_KEY_BASE64) echo "the App Store Connect API key (.p8), a file" ;;
    AWS_*) echo "a stored AWS key: prefer awsRoleArn in .kheona.json (OIDC), and neither secret exists" ;;
  esac
}
missing=()
for s in $(printf '%s\n' "${need[@]+"${need[@]}"}" | awk '!seen[$0]++'); do [[ " $have " == *" $s "* ]] || missing+=("$s"); done
if [ "$have" = '?' ]; then todo "secrets unreadable: does this login have admin on $REPO?"
elif [ ${#missing[@]} = 0 ]; then ok "secrets (${#need[@]} needed, all set)"
elif $APPLY && [ -t 0 ]; then
  for s in "${missing[@]}"; do
    echo; echo "$s: $(hint "$s")."
    if [[ $s == *_BASE64 ]]; then
      read -r -p "  Path of the file (empty: skip): " f
      if [ -n "$f" ] && [ -f "$f" ]; then base64 < "$f" | tr -d '\n' | gh secret set "$s" --repo "$REPO" > /dev/null && did "secret $s" || todo "secret $s: gh refused it"
      else todo "secret $s: skipped"; fi
    else
      read -r -s -p "  Value (hidden, empty: skip): " v; echo
      if [ -n "$v" ]; then printf '%s' "$v" | gh secret set "$s" --repo "$REPO" > /dev/null && did "secret $s" || todo "secret $s: gh refused it"
      else todo "secret $s: skipped"; fi
      unset v
    fi
  done
else for s in "${missing[@]}"; do todo "secret $s: $(hint "$s") (--apply in a terminal asks for it)"; done; fi

# 8. The repository check, from this version's files.
if bash "$SKILL/scripts/kskill-repo-check.sh" "$DIR" "$SKILL" > "$DIR/.git/kskill-setup-check.txt" 2>&1; then ok "repository check"
else todo "repository check fails: $(grep -m1 -E '^(error|::error)' "$DIR/.git/kskill-setup-check.txt" | cut -c1-160)"; fi

# 9. The proof: what this run wrote goes in one PR, whose CI runs the gate this repository now has.
changes=$(git -C "$DIR" status --porcelain)
if [ -z "$changes" ]; then ok "nothing to commit"
elif $APPLY; then
  branch=chore/kheona-skill-setup
  git -C "$DIR" switch -q -c "$branch" && git -C "$DIR" add -A && git -C "$DIR" commit -q -m "chore(ci): kheona-skill $VERSION setup" &&
    git -C "$DIR" push -q -u origin "$branch" && url=$(gh pr create --repo "$REPO" --head "$branch" --title "chore(ci): kheona-skill $VERSION setup" \
      --body "Written by kheona-skill's setup command (scripts/kskill-setup.sh): $(git -C "$DIR" show --stat --format= HEAD | tail -1). Its CI is the proof.") &&
    did "PR $url: merge it once CI is green" || todo "the PR: commit and push $branch by hand"
else todo "$(wc -l <<<"$changes" | tr -d ' ') file(s) to commit: --apply opens the PR"; fi

[ "$TODO" = 0 ] && echo "Set up: run this again any time; it only checks." || echo "Left to do above; run this again once done."
exit "$TODO"
