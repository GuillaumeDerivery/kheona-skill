#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck disable=SC2016 # why: the test patterns match Markdown backticks, not command substitutions
# Offline tests for .github/scripts/kskill-release.sh (the release PR's "Check before you merge"), against throwaway
# git repositories. A local branch stands in for origin/main (KSKILL_MAIN); version tags mark the last release.
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
  OUT=$(cd "$R" && KSKILL_MAIN=main GITHUB_REPOSITORY=o/r KSKILL_FORK=${FORK:-false} GITHUB_OUTPUT='' bash "$REL" "$@" 2>&1); CODE=$?
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

NODE_CFG='{"role":"project","workflows":{"cd":{"prod":{"ecrRepository":"svc","region":"eu-west-1","cluster":"c1","namespace":"prod","deployments":["api"],"cronjobs":["nightly"]},"staging":false}}}'

# --- skips: nothing printed ---------------------------------------------------------------------------------
for case in 'library|{"role":"library"}' 'cd off|{"role":"project","workflows":{"cd":{"enabled":false}}}' \
            'template|{"role":"template"}' 'no production|{"role":"project","workflows":{"cd":{"prod":false}}}'; do
  IFS='|' read -r name cfg <<<"$case"
  new_repo "skip-${name// /-}"; commit init .kheona.json "$cfg"; commit 'feat: x'
  run notes; check "skip: $name prints nothing" [ "$CODE" = 0 ] && check "skip: $name, no section" not grep -q 'Check before' <<<"$OUT"
done
new_repo nocfg; commit init README.md x
run notes; expect "no .kheona.json: nothing" 0 'no .kheona.json'

# --- a service ---------------------------------------------------------------------------------------------
new_repo svc
commit 'chore: init' .kheona.json "$NODE_CFG" package.json '{"name":"svc","version":"1.4.0"}' config/base.json '{"api":{"port":1}}' src/a.ts 'const a = 1;'
g tag v1.4.0
commit 'feat(auth): passkey step-up (#12)' src/a.ts 'const a = process.env.NEW_SECRET;'
commit 'fix: crash on empty cart (#13)' migrations/001-add-index.js 'up'
commit 'chore(deps): bump express to 5.2.0 (#14)' package-lock.json '{}'
commit 'feat!: drop the v1 routes (#15)' config/base.json '{"api":{"port":1,"newKey":"x"}}'
run notes; B=$OUT
expect "service: the section" 0 '^### Check before you merge$'
check "service: between markers" grep -q '^<!-- kskill-release-notes:end -->$' <<<"$B"
check "service: since the last tag" grep -q 'Since v1.4.0: 4 change(s)' <<<"$B"
check "service: breaking risk" grep -qE 'Breaking change.*#15' <<<"$B"
check "service: migration risk" grep -qE 'Migrations.*migrations/001-add-index.js' <<<"$B"
check "service: config key risk" grep -qE 'Configuration keys added.*config/base.json.*api\.newKey' <<<"$B"
check "service: env var risk" grep -qE 'Environment variables newly read.*NEW_SECRET' <<<"$B"
check "service: lockfile risk" grep -qE 'Dependencies.*package-lock.json' <<<"$B"
check "service: deploy targets" grep -qE 'Namespace `prod`: deployment `api`, cron job `nightly`' <<<"$B"
check "service: by digest, on the tag" grep -qE 'by digest' <<<"$B"
check "service: nothing about a prod branch" not grep -qE 'prod`? branch|ship`' <<<"$B"
g tag v1.5.0
run notes; check "service: right after a release, nothing detected" grep -q 'Nothing detected' <<<"$OUT"
new_repo custom
commit 'chore: init' .kheona.json '{"role":"project","workflows":{"cd":{"target":"custom","prod":{}}}}'
run notes; check "custom target: its own workflow" grep -q 'workflows.cd.target' <<<"$OUT"
check "custom target: no release yet, from the first commit" grep -q 'Since the first commit' <<<"$OUT"

# --- a submodule: its versions from its repository's tags (a fake gh) -----------------------------------------
LA=1111111111111111111111111111111111111111; LB=2222222222222222222222222222222222222222; LC=3333333333333333333333333333333333333333
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<GH
#!/usr/bin/env bash
jqx=.; while [ "\$#" -gt 0 ]; do [ "\$1" = --jq ] && jqx=\$2; shift; done
echo '[{"name":"v3.2.0","commit":{"sha":"$LA"}},{"name":"v3.3.0","commit":{"sha":"$LC"}},{"name":"v4.0.0","commit":{"sha":"$LB"}}]' | jq -r "\$jqx"
GH
chmod +x "$T/fakebin/gh"
sub() { g update-index --add --cacheinfo "160000,$1,submodules/lib"; g commit -q -m "$2"; }
new_repo sub
commit 'chore: init' .kheona.json "$NODE_CFG" .gitmodules '[submodule "lib"]
	path = submodules/lib
	url = https://github.com/owner/lib.git'
sub "$LA" 'chore: lib v3.2.0'; g tag v1.0.0
sub "$LB" 'feat: lib v4 (#3)'
OUT=$(cd "$R" && PATH="$T/fakebin:$PATH" KSKILL_MAIN=main GITHUB_REPOSITORY=o/r bash "$REL" notes 2>&1)
check "submodule: a major version is called out" grep -qE 'submodules/lib` moves v3.2.0 -> v4.0.0: \*\*a major version' <<<"$OUT"
g tag v1.1.0; sub "$LC" 'fix: lib back to 3.3 (#4)'
OUT=$(cd "$R" && PATH="$T/fakebin:$PATH" KSKILL_MAIN=main GITHUB_REPOSITORY=o/r bash "$REL" notes 2>&1)
check "submodule: a major version down is called out too" grep -qE 'v4.0.0 -> v3.3.0: \*\*a major' <<<"$OUT"
g tag v1.2.0; sub "$LA" 'fix: lib 3.2 (#5)'
OUT=$(cd "$R" && PATH="$T/fakebin:$PATH" KSKILL_MAIN=main GITHUB_REPOSITORY=o/r bash "$REL" notes 2>&1)
check "submodule: a minor move, versions only" grep -qE 'moves v3.3.0 -> v3.2.0\.$' <<<"$OUT"
mkdir -p "$T/nogh"; printf '#!/usr/bin/env bash\necho "HTTP 404" >&2; exit 1\n' > "$T/nogh/gh"; chmod +x "$T/nogh/gh"
OUT=$(cd "$R" && PATH="$T/nogh:$PATH" KSKILL_MAIN=main GITHUB_REPOSITORY=o/r bash "$REL" notes 2>&1)
check "submodule: no access to its repository, SHAs and a hint" grep -qE 'moves 3333333 -> 1111111\. Versions unknown' <<<"$OUT"

# --- an app ------------------------------------------------------------------------------------------------
new_repo app
FL_CFG='{"role":"app","workflows":{"cd":{"ios":{"xcode":"26.6"},"android":{"lane":"internal"}}}}'
commit 'chore: init' .kheona.json "$FL_CFG" pubspec.yaml 'name: app
version: 0.2.0+1' lib/main.dart 'void main() {}'
g tag v0.2.0
commit 'feat(onboarding): new welcome screen (#21)' lib/main.dart 'void main() { const bool.fromEnvironment("BETA"); }'
commit 'fix(auth): token refresh (#23)' ios/Runner/Info.plist '<plist/>'
run notes; B=$OUT
check "app: Play lane" grep -qE 'Google Play.*lane `internal`' <<<"$B"
check "app: TestFlight with Xcode" grep -qE 'TestFlight.*lane `beta`.*Xcode 26.6' <<<"$B"
check "app: delivered on the tag" grep -q 'when the version tag is pushed' <<<"$B"
check "app: native settings risk" grep -qE 'Native app settings.*Info.plist' <<<"$B"
check "app: dart-define risk" grep -qE 'Environment variables newly read.*BETA' <<<"$B"

echo "release: $pass passed, $failn failed"
[ "$failn" = 0 ]
