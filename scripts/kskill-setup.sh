#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck disable=SC2016  # why: the single-quoted strings are jq programs; their $names are jq variables
# The setup command: brings one repository onto this version of kheona-skill, and says what is left. Guided and
# resumable: every step checks first, a step already done says so, and a run stopped anywhere (q, Ctrl-C, a closed
# terminal) picks up where it stopped the next time. Without --apply it changes nothing.
#
# Usage: kskill-setup.sh [--apply] <owner/repo> <clone>
#   <clone>  a local clone of the repository, on its default branch, clean.
#   --apply  writes what is missing in the clone (.kheona.json, release files, callers, the Renovate preset) and opens
#            one PR with it (its CI is the proof); applies the repository settings and topic; sets the variables it
#            can; in a terminal, walks through each missing secret, one at a time, and waits while a person sets it.
# Env: KSKILL_BOT (the App's <app-slug>[bot]) and KSKILL_TOKEN_BROKER_URL (its broker): set as variables when missing;
#      read back from the repository's variables when already set there.
# Steps: 1 .kheona.json, 2 topic, 3 the App installed, 4 release files, 5 callers and Renovate preset, 6 settings,
#        7 variables, 8 secrets (the store secrets walked through one by one), 9 the repository check, 10 the PR.
# Prints one line per step: "ok", "done" (with --apply), "todo" (left to do: what and how). Exit 1 when a todo is left.
# Secrets: names only. This command never reads, asks for, prints or stores a secret's value: for each missing one it
# says what it is, where to find it and the exact `gh secret set` command a person runs (gh asks for the value itself,
# hidden, or reads the encoded file from a pipe), then checks the name again. A person's answers that GitHub can't
# confirm (the App installed on a personal account) are kept in the clone's .git/kskill-setup.state, never committed.
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
note() { printf 'note  %s\n' "$1"; }
cfg() { jq -r "$1 // empty" "$DIR/.kheona.json" 2>/dev/null; }
stack() {
  if [ -f "$DIR/pubspec.yaml" ]; then echo flutter; elif [ -f "$DIR/package.json" ]; then echo node
  elif [ -f "$DIR/pyproject.toml" ] || [ -f "$DIR/Pipfile" ]; then echo python; elif ls "$DIR"/*.tf "$DIR"/terraform >/dev/null 2>&1; then echo infra; fi
}

# A person at the keyboard: a terminal on stdin (KSKILL_SETUP_TTY=1 stands for one in the tests).
interactive() { $APPLY && { [ "${KSKILL_SETUP_TTY:-}" = 1 ] || [ -t 0 ]; }; }
# What a person confirmed and GitHub can't show this login, one "<key> <value>" line each, in the clone's .git.
STATE="$(git -C "$DIR" rev-parse --absolute-git-dir 2>/dev/null || echo "$DIR/.git")/kskill-setup.state"
remembered() { grep -qxF "$1" "$STATE" 2>/dev/null; }
remember() { remembered "$1" || echo "$1" >> "$STATE"; }
OWNER=${REPO%%/*}

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

# The two variables every shared workflow needs, read back from the repository when this shell does not set them
# (variables are not secrets: their values are readable).
var() { gh api "repos/$REPO/actions/variables/$1" --jq .value 2>/dev/null; }
KSKILL_BOT=${KSKILL_BOT:-$(var KSKILL_BOT)}
KSKILL_TOKEN_BROKER_URL=${KSKILL_TOKEN_BROKER_URL:-$(var KSKILL_TOKEN_BROKER_URL)}

# 3. The App installed on the repository: its broker mints tokens only for an installation. An organization's
# installations are readable with admin:org; a personal account's are not (GitHub answers only an App's own token),
# so a person looks once and the answer is remembered.
slug=${KSKILL_BOT%\[bot\]}
if [ -z "$slug" ]; then todo "the App: set KSKILL_BOT ('<app-slug>[bot]') to check it is installed"
elif remembered "app-installed $REPO $slug"; then ok "App $slug installed (confirmed by a person)"
else
  sel=$(gh api "orgs/$OWNER/installations?per_page=100" --jq ".installations[] | select(.app_slug == \"$slug\") | .repository_selection" 2>/dev/null)
  if [ "$sel" = all ]; then ok "App $slug installed (every repository of $OWNER)"
  else
    if [ "$(gh api "users/$OWNER" --jq .type 2>/dev/null)" = Organization ]; then where="https://github.com/organizations/$OWNER/settings/installations"
    else where="https://github.com/settings/installations"; fi
    if interactive; then
      echo; echo "The App $slug: open $where, Configure next to it, and check that Repository access lists $REPO"
      echo "  (or is All repositories). Not installed yet: its public page, https://github.com/apps/$slug, Install."
      read -r -p "  Is $REPO listed? [y/N] " a
      if [ "$a" = y ] || [ "$a" = Y ]; then remember "app-installed $REPO $slug"; did "App $slug installed (confirmed, remembered in $STATE)"
      else todo "the App $slug on $REPO: install it ($where), then run this again"; fi
    else todo "the App $slug installed on $REPO: $where, Configure, Repository access (--apply in a terminal asks and remembers)"; fi
  fi
fi

# 4. Release files, where a version tag ships something: a manifest seeded at the current version, on several lines
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

# 5. The callers and the Renovate preset, exactly what this version writes.
if node "$SKILL/scripts/kskill-callers.mjs" check --repo "$DIR" > /dev/null 2>&1 && grep -q "renovate/default#$VERSION" "$DIR/renovate.json" 2>/dev/null; then ok "callers at $VERSION"
elif $APPLY; then
  [ -f "$DIR/renovate.json" ] || jq -n --arg s "$SELF" --arg v "$VERSION" '{"$schema": "https://docs.renovatebot.com/renovate-schema.json", extends: ["github>\($s)//renovate/default#\($v)"]}' > "$DIR/renovate.json"
  node "$SKILL/scripts/kskill-callers.mjs" write --repo "$DIR" --self "$SELF" --sha "$SHA" --version "$VERSION" > /dev/null && did "callers and the Renovate preset at $VERSION"
else todo "callers: --apply writes them at $VERSION"; fi

# 6. Repository settings (squash merges, workflow permissions, the KSKILL_* variables the configuration implies).
settings=(bash "$SKILL/scripts/kskill-repo-settings.sh" "$REPO")
if [ -z "${KSKILL_BOT:-}" ]; then todo "settings: KSKILL_BOT (your App's <app-slug>[bot]) is needed to check them"
elif "${settings[@]}" > /dev/null 2>&1; then ok "settings"
elif $APPLY && "${settings[@]}" --apply > /dev/null 2>&1; then did "settings"
else todo "settings drift: KSKILL_BOT=$KSKILL_BOT ${settings[*]} shows it; --apply sets them"; fi

# 7. Variables, the two every shared workflow needs: the App's bot and its broker.
vars=$(gh api "repos/$REPO/actions/variables?per_page=100" --jq '[.variables[].name] | join(" ")' 2>/dev/null || echo '?')
for v in KSKILL_BOT KSKILL_TOKEN_BROKER_URL; do
  val=${!v:-}
  if [ "$vars" = '?' ]; then todo "variable $v: variables unreadable, does this login have admin on $REPO?"
  elif [[ " $vars " == *" $v "* ]]; then ok "variable $v"
  elif $APPLY && [ -n "$val" ] && gh variable set "$v" --repo "$REPO" --body "$val" > /dev/null; then did "variable $v"
  else todo "variable $v: set $v in this shell and --apply, or gh variable set $v --repo $REPO --body '<value>'"; fi
done

# 8. Secrets, names only: the ones a workflow here fails without.
have=$(gh secret list --repo "$REPO" --json name --jq '[.[].name] | join(" ")' 2>/dev/null || echo '?')
need=() delivers=false
if [ -f "$DIR/.github/workflows/kskill-deliver.yml" ] && [ "$(cfg .workflows.cd.enabled)" != false ]; then
  delivers=true
  [ "$(cfg .workflows.cd.android.enabled)" = false ] || need+=(ANDROID_KEYSTORE_BASE64
    ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD ANDROID_PLAY_STORE_JSON_KEY_BASE64)
  [ "$(cfg .workflows.cd.ios.enabled)" = false ] || need+=(APPLE_DIST_CERTIFICATE_P12_BASE64
    APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_BASE64)
fi
if [ -f "$DIR/.github/workflows/kskill-deploy.yml" ]; then
  for env in staging prod; do
    t=$(jq -r --arg e "$env" '.workflows.cd[$e] | type' "$DIR/.kheona.json" 2>/dev/null)
    [ "$t" = object ] && [ -z "$(cfg ".workflows.cd.$env.awsRoleArn")" ] && need+=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY)
  done
fi
# The walkthrough of one secret: what it is, where to find it, the command that sets it, what goes wrong. Commands
# only: gh reads the value itself (hidden at its prompt, or the encoded file from the pipe), never this script.
guide() {
  local n=$1 set="gh secret set $1 --repo $REPO" file
  case $n in
    ANDROID_KEYSTORE_BASE64)
      echo "  What: the upload keystore (.jks or .keystore) that signs the bundle Google Play receives, base64 on one line."
      echo "  Where: the keystore the app's first upload was signed with. Play Console, the app, Test and release, App integrity,"
      echo "    shows the upload certificate's SHA-1: it must match keytool -list -v -keystore upload.jks. A new app makes one:"
      echo "    keytool -genkeypair -v -keystore upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload"
      echo "  Pitfall: no Java installed? keytool ships with Android Studio:"
      echo "    \"/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool\""
      file=upload.jks ;;
    ANDROID_KEYSTORE_PASSWORD)
      echo "  What: the upload keystore's password (the one keytool asks for)."
      echo "  Where: whoever made the keystore; a password manager. It never goes in a file of the repository." ;;
    ANDROID_KEY_ALIAS)
      echo "  What: the upload key's alias inside the keystore (often upload)."
      echo "  Where: keytool -list -keystore upload.jks prints each alias (it asks for the keystore password)." ;;
    ANDROID_KEY_PASSWORD)
      echo "  What: the upload key's own password."
      echo "  Pitfall: a PKCS12 keystore (keytool's default since Java 9) has one password: the key's is the keystore's." ;;
    ANDROID_PLAY_STORE_JSON_KEY_BASE64)
      echo "  What: a Google Cloud service account's JSON key, allowed to release this app on Google Play, base64 on one line."
      echo "  Where: Google Cloud console, IAM and admin, Service accounts, the account, Keys, Add key, JSON (downloaded once)."
      echo "    Then Play Console, Users and permissions, invite the account's e-mail with the release permissions on this app."
      echo "  Pitfall: the Google Play Android Developer API must be enabled in that Cloud project; an organization policy"
      echo "    (iam.disableServiceAccountKeyCreation) can forbid creating keys."
      file=play-service-account.json ;;
    APPLE_DIST_CERTIFICATE_P12_BASE64)
      echo "  What: the Apple Distribution certificate with its private key, exported as .p12, base64 on one line."
      echo "  Where: Keychain Access on the Mac that created it, My Certificates, \"Apple Distribution: ...\": expand it,"
      echo "    select the certificate and its key, Export 2 items, .p12. None there: developer.apple.com, Certificates, +,"
      echo "    Apple Distribution, from a request made in Keychain Access (Certificate Assistant)."
      echo "  Password: exported with one, set it too: gh secret set APPLE_DIST_CERTIFICATE_PASSWORD --repo $REPO."
      echo "    Without one, leave APPLE_DIST_CERTIFICATE_PASSWORD unset (GitHub cannot store an empty secret): the delivery"
      echo "    imports the .p12 with an empty password, re-encoding it first when it was made with OpenSSL."
      echo "  Pitfall: to look inside it, macOS's /usr/bin/openssl is LibreSSL and cannot read a modern PKCS#12:"
      echo "    use Homebrew's OpenSSL 3, \"\$(brew --prefix openssl@3)/bin/openssl\" pkcs12 -in cert.p12 -noout -info, adding -legacy"
      echo "    for an older RC2-encrypted file."
      file=cert.p12 ;;
    APPLE_API_KEY_ID)
      echo "  What: the App Store Connect API key's id (10 characters)."
      echo "  Where: App Store Connect, Users and Access, Integrations, App Store Connect API, Team Keys: the Key ID column."
      echo "    A new key: +, access App Manager (never Admin)." ;;
    APPLE_API_ISSUER_ID)
      echo "  What: the App Store Connect issuer id (a UUID)."
      echo "  Where: the same page, Issuer ID, above the keys." ;;
    APPLE_API_KEY_BASE64)
      echo "  What: that API key's private key, AuthKey_<id>.p8, base64 on one line."
      echo "  Pitfall: App Store Connect lets you download it once, when the key is made: lost, revoke it and make another."
      file=AuthKey_XXXXXXXXXX.p8 ;;
    AWS_*)
      echo "  What: a stored AWS key. Prefer none: awsRoleArn in .kheona.json (OIDC) needs neither secret (docs/kheona-json.md)." ;;
  esac
  if [ -n "${file:-}" ]; then printf '  Set it (from the file'"'"'s folder): base64 < %s | tr -d '"'"'\\n'"'"' | %s\n' "$file" "$set"
  else echo "  Set it: $set   (gh asks for the value, hidden)"; fi
}
missing=()
for s in $(printf '%s\n' "${need[@]+"${need[@]}"}" | awk '!seen[$0]++'); do
  [[ " $have " == *" $s "* ]] || missing+=("$s")
done
# The delivery's old secret names (before v2.9.0), no longer read: one left over is said, with its new name.
if $delivers && [ "$have" != '?' ]; then
  for pair in CM_KEYSTORE_PASSWORD:ANDROID_KEYSTORE_PASSWORD CM_KEY_ALIAS:ANDROID_KEY_ALIAS CM_KEY_PASSWORD:ANDROID_KEY_PASSWORD \
    PLAY_STORE_JSON_KEY_BASE64:ANDROID_PLAY_STORE_JSON_KEY_BASE64 IOS_DIST_CERTIFICATE_P12_BASE64:APPLE_DIST_CERTIFICATE_P12_BASE64 \
    IOS_DIST_CERTIFICATE_PASSWORD:APPLE_DIST_CERTIFICATE_PASSWORD ASC_KEY_ID:APPLE_API_KEY_ID ASC_ISSUER_ID:APPLE_API_ISSUER_ID \
    ASC_API_KEY_BASE64:APPLE_API_KEY_BASE64; do
    old=${pair%%:*} new=${pair#*:}
    [[ " $have " == *" $old "* ]] && note "secret $old is no longer read: $new replaces it; once $new is set, gh secret delete $old --repo $REPO"
  done
fi
if [ "$have" = '?' ]; then todo "secrets unreadable: does this login have admin on $REPO?"
elif [ ${#missing[@]} = 0 ]; then ok "secrets (${#need[@]} needed, all set)"
elif interactive; then
  echo; echo "${#missing[@]} secret(s) to set, one at a time. Run each command in another terminal; this waits, then checks the name."
  stop=false
  for s in "${missing[@]}"; do
    if $stop; then todo "secret $s: not set yet (run this again to continue)"; continue; fi
    echo; echo "$s"; guide "$s"
    read -r -p "  Enter once it is set, s to skip it, q to stop here: " a
    if [ "$a" = q ]; then stop=true; todo "secret $s: not set yet (run this again to continue)"; continue; fi
    if [ "$a" = s ]; then todo "secret $s: skipped"; continue; fi
    now=$(gh secret list --repo "$REPO" --json name --jq '[.[].name] | join(" ")' 2>/dev/null)
    if [[ " $now " == *" $s "* ]]; then did "secret $s"; else todo "secret $s: GitHub does not list it yet"; fi
  done
else for s in "${missing[@]}"; do todo "secret $s"; guide "$s"; done; fi

# 9. The repository check, from this version's files.
if bash "$SKILL/scripts/kskill-repo-check.sh" "$DIR" "$SKILL" > "$DIR/.git/kskill-setup-check.txt" 2>&1; then ok "repository check"
else todo "repository check fails: $(grep -m1 -E '^(error|::error)' "$DIR/.git/kskill-setup-check.txt" | cut -c1-160)"; fi

# 10. The proof: what this run wrote goes in one PR, whose CI runs the gate this repository now has.
changes=$(git -C "$DIR" status --porcelain)
if [ -z "$changes" ]; then ok "nothing to commit"
elif $APPLY; then
  # A re-run finds its branch and its PR again: the new files join them.
  branch=chore/kheona-skill-setup
  { git -C "$DIR" switch -q -c "$branch" 2>/dev/null || git -C "$DIR" switch -q "$branch"; } && git -C "$DIR" add -A &&
    git -C "$DIR" commit -q -m "chore(ci): kheona-skill $VERSION setup" && git -C "$DIR" push -q -u origin "$branch" &&
    url=$(gh pr view "$branch" --repo "$REPO" --json url --jq .url 2>/dev/null || gh pr create --repo "$REPO" --head "$branch" --title "chore(ci): kheona-skill $VERSION setup" \
      --body "Written by kheona-skill's setup command (scripts/kskill-setup.sh): $(git -C "$DIR" show --stat --format= HEAD | tail -1). Its CI is the proof.") &&
    did "PR $url: merge it once CI is green" || todo "the PR: commit and push $branch by hand"
else todo "$(wc -l <<<"$changes" | tr -d ' ') file(s) to commit: --apply opens the PR"; fi

[ "$TODO" = 0 ] && echo "Set up: run this again any time; it only checks." || echo "Left to do above; run this again once done."
exit "$TODO"
