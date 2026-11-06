#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck disable=SC2016 # why: the test patterns match Markdown backticks, not command substitutions
# Offline tests for .github/scripts/kskill-release.sh, against throwaway git repositories.
# Local branches stand in for origin/main and origin/prod (KSKILL_MAIN / KSKILL_PROD).
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
REL="$HERE/.github/scripts/kskill-release.sh"
T=${KEEP:-$(mktemp -d)}; [ -n "${KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
pass=0; failn=0
ok() { pass=$((pass+1)); echo "ok   $1"; }
ko() { failn=$((failn+1)); echo "FAIL $1"; [ -z "${2:-}" ] || printf '     %s\n' "${2//$'\n'/$'\n'     }"; }
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
commit() { # commit <message> [file content]...: writes each file, commits everything
  local msg=$1; shift
  while [ "$#" -gt 1 ]; do mkdir -p "$(dirname "$R/$1")"; printf '%s\n' "$2" > "$R/$1"; shift 2; done
  g add -A >/dev/null; g commit -q --allow-empty -m "$msg"
}
new_repo() { R="$T/$1"; mkdir -p "$R"; g init -q -b main; }
run() { # run <command> <arg>: output in $OUT, exit code in $CODE
  OUT=$(cd "$R" && KSKILL_MAIN=main KSKILL_PROD=prod GITHUB_REPOSITORY=o/r KSKILL_FORK=${FORK:-false} GITHUB_OUTPUT='' bash "$REL" "$@" 2>&1); CODE=$?
}
field() { cat "$T/out-$1/$2" 2>/dev/null; }
expect() { # expect <name> <command result: code> <grep pattern on output or ->
  if [ "$CODE" = "$2" ] && { [ "$3" = - ] || grep -qE "$3" <<<"$OUT"; }; then ok "$1"; else ko "$1 (exit $CODE, want $2; pattern $3)" "$OUT"; fi
}
check() { # check <name> <condition...>
  local name=$1; shift
  if "$@"; then ok "$name"; else ko "$name" "$OUT"; fi
}
has_text() { grep -qE -- "$2" "$1"; }
not() { ! "$@"; }

NODE_CFG='{"role":"project","workflows":{"cd":{"prod":{"ecrRepository":"svc","region":"eu-west-1","cluster":"c1","namespace":"prod","deployments":["api"],"cronjobs":["nightly"],"healthcheckUrl":"https://api.example.com/healthcheck"},"staging":false}}}'

# --- skips -------------------------------------------------------------------------------------------------
for case in 'library|{"role":"library"}|role is library' \
            'cd off|{"role":"project","workflows":{"cd":{"enabled":false}}}|cd.enabled is false' \
            'release off|{"role":"project","workflows":{"release":{"enabled":false}}}|release.enabled is false' \
            'template|{"role":"template"}|role is template' \
            'no production|{"role":"project","workflows":{"cd":{"prod":false}}}|cd.prod is false'; do
  IFS='|' read -r name cfg want <<<"$case"
  new_repo "skip-${name// /-}"; commit init .kheona.json "$cfg"; g branch prod; commit 'feat: x'
  run prepare "$T/out-skip"
  check "skip: $name" [ "$CODE" = 0 ]
  check "skip status: $name" [ "$(field skip status)" = skip ]
  check "skip reason: $name" grep -q "$want" "$T/out-skip/reason"
  rm -rf "$T/out-skip"
done
new_repo noprod; commit init .kheona.json "$NODE_CFG"
run prepare "$T/out-noprod"; expect "no prod branch skips" 0 'no prod branch'
new_repo nocfg; commit init README.md x; g branch prod; commit 'feat: x'
run prepare "$T/out-nocfg"; expect "no .kheona.json skips" 0 'no .kheona.json'

# --- fast-forward ------------------------------------------------------------------------------------------
new_repo ff
commit 'chore: init' .kheona.json "$NODE_CFG" package.json '{"name":"svc","version":"1.4.0"}' config/base.json '{"api":{"port":1}}' src/a.ts 'const a = 1;'
g branch prod
commit 'feat(auth): passkey step-up (#12)' src/a.ts 'const a = process.env.NEW_SECRET;'
commit 'fix: crash on empty cart (#13)' migrations/001-add-index.js 'up'
commit 'chore(deps): bump express to 5.2.0 (#14)' package-lock.json '{}'
commit 'feat!: drop the v1 routes (#15)' config/base.json '{"api":{"port":1,"newKey":"x"}}'
MAIN_SHA=$(g rev-parse main); PROD_SHA=$(g rev-parse prod)
run prepare "$T/out-ff"
expect "ff: opens" 0 'Release 1.4.0'
check "ff: status open" [ "$(field ff status)" = open ]
check "ff: head is main itself" [ "$(field ff head)" = "$MAIN_SHA" ]
check "ff: mode" [ "$(field ff mode)" = fast-forward ]
check "ff: title names the features" has_text "$T/out-ff/title" '^Release 1\.4\.0 [0-9a-f]{7} — passkey step-up; drop the v1 routes$'
B="$T/out-ff/body.md"
check "ff: features group" has_text "$B" '^#### Features$'
check "ff: scoped feature with PR" has_text "$B" '^- \*\*auth\*\*: passkey step-up \(#12\) [0-9a-f]{7}$'
check "ff: fixes group" has_text "$B" '^- crash on empty cart \(#13\)'
check "ff: dependencies group" has_text "$B" '^#### Dependencies$'
check "ff: breaking flagged in list" has_text "$B" '^- \*\*BREAKING\*\* drop the v1 routes \(#15\)'
check "ff: breaking risk" has_text "$B" 'Breaking change.*#15'
check "ff: migration risk" has_text "$B" 'Migrations.*migrations/001-add-index.js'
check "ff: config key risk" has_text "$B" 'Configuration keys added.*config/base.json.*api\.newKey'
check "ff: env var risk" has_text "$B" 'Environment variables newly read.*NEW_SECRET'
check "ff: lockfile risk" has_text "$B" 'Dependencies.*package-lock.json'
check "ff: deploy targets" has_text "$B" 'Namespace `prod`: deployment `api`, cron job `nightly`'
check "ff: image tag is the head" has_text "$B" "\`svc\`:\`$MAIN_SHA\`"
check "ff: no release commit block" not has_text "$B" 'Release commit'
run verify "$MAIN_SHA"; expect "ff: verify main" 0 'fast-forward'
run verify "$(g rev-parse main~1)"; expect "ff: verify an older main commit" 0 -
run verify "$PROD_SHA"; expect "ff: verify prod itself fails" 1 'already at'
g checkout -q -b side prod; commit 'feat: not on main'; SIDE=$(g rev-parse side); g checkout -q main
run verify "$SIDE"; expect "ff: verify a commit off main fails" 1 'not on main'
run verify "$(g rev-parse main~1 | cut -c1-12)"; expect "ff: verify a short SHA fails" 1 'not a full commit SHA'
FORK=true run verify "$MAIN_SHA"; expect "ff: a fork ships like any repository" 0 'OK: prod'
g branch -f prod main
run prepare "$T/out-none"; expect "ff: nothing to release" 0 'Nothing to release'
check "ff: status none" [ "$(field none status)" = none ]
g branch -f prod side
run prepare "$T/out-div"; expect "ff: diverged prod fails" 1 'commit\(s\) main lacks'
run verify "$MAIN_SHA"; expect "ff: verify onto diverged prod fails" 1 'does not descend from prod'

# --- squash (Flutter) --------------------------------------------------------------------------------------
new_repo sq
FL_CFG='{"role":"app","workflows":{"release":{"squash":true},"cd":{"ios":{"xcode":"26.6"},"android":{"lane":"internal"},"buildNumber":{"offset":100}}}}'
commit 'chore: init' .kheona.json "$FL_CFG" pubspec.yaml 'name: app
version: 0.2.0+1' lib/main.dart 'void main() {}'
FIRST=$(g rev-parse main)
# prod: an unrelated history whose last release commit names main's first commit
g checkout -q --orphan prod; commit "Release 0.1.0 (101) — first

- App: first.

Squash of origin/main at ${FIRST:0:7}"
g checkout -q main
commit 'feat(onboarding): new welcome screen (#21)' lib/main.dart 'void main() { const bool.fromEnvironment("BETA"); }'
commit 'docs: readme (#22)' README.md x
commit 'fix(auth): token refresh (#23)' ios/Runner/Info.plist '<plist/>'
MAIN_SHA=$(g rev-parse main); PROD_SHA=$(g rev-parse prod)
run prepare "$T/out-sq"
expect "squash: opens" 0 'Release 0.2.0'
H=$(field sq head)
check "squash: mode" [ "$(field sq mode)" = squash ]
check "squash: head is one commit on prod" [ "$(g rev-parse "$H^@")" = "$PROD_SHA" ]
check "squash: head holds main's tree" [ "$(g rev-parse "$H^{tree}")" = "$(g rev-parse "main^{tree}")" ]
check "squash: build = prod count + 1 + offset" has_text "$T/out-sq/title" '^Release 0\.2\.0 \(102\) — new welcome screen; token refresh$'
M=$(g log -1 --format=%B "$H")
check "squash: message title" grep -q '^Release 0.2.0 (102)' <<<"$M"
check "squash: area bullets" grep -q '^- Onboarding: new welcome screen. (#21)$' <<<"$M"
check "squash: docs bullet" grep -q '^- Docs: readme. (#22)$' <<<"$M"
check "squash: squash line last" [ "$(sed '/^$/d' <<<"$M" | tail -1)" = "Squash of origin/main at ${MAIN_SHA:0:7}" ]
check "squash: only commits since the last release" not grep -q 'init' <<<"$M"
B="$T/out-sq/body.md"
check "squash: release commit shown" has_text "$B" 'Release commit'
check "squash: Play lane" has_text "$B" 'Google Play.*lane `internal`.*build 102'
check "squash: TestFlight with Xcode" has_text "$B" 'TestFlight.*lane `beta`.*Xcode 26.6'
check "squash: native settings risk" has_text "$B" 'Native app settings.*Info.plist'
check "squash: dart-define risk" has_text "$B" 'Environment variables newly read.*BETA'
run prepare "$T/out-sq2"
check "squash: the same inputs give the same head" [ "$(field sq2 head)" = "$H" ]
run verify "$H"; expect "squash: verify the release commit" 0 'fast-forward'
run verify "$MAIN_SHA"; expect "squash: verify main itself fails" 1 'does not descend from prod|not one commit'
TAMPER=$(g commit-tree "$PROD_SHA^{tree}" -p "$PROD_SHA" -m "x

Squash of origin/main at ${MAIN_SHA:0:7}")
run verify "$TAMPER"; expect "squash: verify a commit without main's tree fails" 1 "does not hold main's tree"
g branch -f prod "$H"
run prepare "$T/out-sq3"; expect "squash: nothing after the release" 0 'Nothing to release'

# A fork of a template that deploys: the PR opens and it ships, like any repository.
new_repo fork
commit 'chore: init' .kheona.json '{"role":"template","workflows":{"cd":{"prod":{"ecrRepository":"x","region":"r","cluster":"c","namespace":"n","deployments":["d"]}}}}'
g branch prod; commit 'feat: y'
FORK=true run prepare "$T/out-fork"; expect "fork: the PR opens" 0 'Release'
FORK=true run verify "$(g rev-parse main)"; expect "fork: ships" 0 'OK: prod'

echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
