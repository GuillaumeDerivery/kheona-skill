#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline tests for scripts/kskill-repos.sh: the one listing of repositories by topic, against a fake `gh` and
# --from fixtures. No network, no credentials.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
REPOS="$HERE/scripts/kskill-repos.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
check() { # check <name> <output> <expected output>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"
  else failn=$((failn+1)); echo "FAIL $1"; printf '     got:  %s\n' "${2//$'\n'/$'\n'           }"; printf '     want: %s\n' "${3//$'\n'/$'\n'           }"; fi
}

# Two pages, as `gh api --paginate --slurp` prints them: tagged, archived, forks, an untagged one, a duplicate.
cat > "$T/pages.json" <<'EOF'
[[{"full_name":"org/b","fork":false,"archived":false,"topics":["kheona-skill","kheona-lib"],"html_url":"https://github.com/org/b","default_branch":"main"},
  {"full_name":"org/a","fork":false,"archived":false,"topics":["kheona-skill"],"html_url":"https://github.com/org/a","default_branch":"main"},
  {"full_name":"org/old","fork":false,"archived":true,"topics":["kheona-skill","kheona-lib"]},
  {"full_name":"org/plain","fork":false,"archived":false,"topics":[]}],
 [{"full_name":"fork/b","fork":true,"archived":false,"topics":["kheona-skill","kheona-lib"]},
  {"full_name":"org/notopics","fork":false,"archived":false},
  {"full_name":"org/a","fork":false,"archived":false,"topics":["kheona-skill"]}]]
EOF
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
[ "\$*" = "api --paginate --slurp user/repos?per_page=100&affiliation=owner,collaborator,organization_member" ] || { echo "fake gh: unexpected \$*" >&2; exit 1; }
[ -n "\${FAKE_GH_FAIL:-}" ] && { echo "gh: Bad credentials (HTTP 401)" >&2; exit 1; }
cat "$T/pages.json"
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
mkdir -p "$T/nogh"; printf '#!/usr/bin/env bash\necho "fake gh: --from must not call GitHub" >&2; exit 1\n' > "$T/nogh/gh"; chmod +x "$T/nogh/gh"

check "every reachable non-archived repository, sorted, once" "$(bash "$REPOS")" $'fork/b\norg/a\norg/b\norg/notopics\norg/plain'
check "--topic keeps the tagged ones, forks included"         "$(bash "$REPOS" --topic kheona-skill)" $'fork/b\norg/a\norg/b'
check "--forks exclude"                                       "$(bash "$REPOS" --topic kheona-lib --forks exclude)" 'org/b'
check "--forks only"                                          "$(bash "$REPOS" --forks only)" 'fork/b'
check "--exclude, repeatable"                                 "$(bash "$REPOS" --topic kheona-skill --exclude org/a --exclude fork/b)" 'org/b'
check "an archived repository is never listed"                "$(bash "$REPOS" --topic kheona-lib --forks include)" $'fork/b\norg/b'
check "--json: the fields callers read"                       "$(bash "$REPOS" --topic kheona-lib --forks exclude --json)" \
  '[{"full_name":"org/b","fork":false,"topics":["kheona-skill","kheona-lib"],"html_url":"https://github.com/org/b","default_branch":"main"}]'
bash "$REPOS" --json > "$T/all.json"
check "--from a page listing: no GitHub call"                 "$(PATH="$T/nogh:$PATH" bash "$REPOS" --from "$T/pages.json" --topic kheona-skill --forks exclude)" $'org/a\norg/b'
check "--from its own --json output"                          "$(PATH="$T/nogh:$PATH" bash "$REPOS" --from "$T/all.json" --topic kheona-lib)" $'fork/b\norg/b'
FAKE_GH_FAIL=1 bash "$REPOS" >/dev/null 2>&1; check "GitHub unreachable: exit non-zero" "$?" 1
bash "$REPOS" --forks maybe >/dev/null 2>&1; check "a bad --forks value: usage error" "$?" 64

# One definition: nothing else in this repository lists the reachable repositories itself.
others=$(cd "$HERE" && grep -rlE "user/repos[?']" scripts tools doctor .github/workflows templates 2>/dev/null | grep -v '^scripts/kskill-repos.sh$' || true)
check "no other script or workflow calls user/repos" "$others" ''

# KSKILL_APP_TOKENS: one listing per installation token (curl), topics read per repository.
mkdir -p "$T/curlbin"
cat > "$T/curlbin/curl" <<'FAKE'
#!/usr/bin/env bash
tok="" url=""
for a in "$@"; do case "$a" in "Authorization: Bearer "*) tok=${a#Authorization: Bearer } ;; https://*) url=$a ;; esac; done
case "$tok $url" in
  "t1 https://api.github.com/installation/repositories?per_page=100&page=1") echo '{"repositories":[{"full_name":"one/a","fork":false,"archived":false},{"full_name":"one/old","fork":false,"archived":true}]}' ;;
  "t2 https://api.github.com/installation/repositories?per_page=100&page=1") echo '{"repositories":[{"full_name":"two/b","fork":true,"archived":false}]}' ;;
  "t1 https://api.github.com/repos/one/a/topics") echo '{"names":["kheona-skill"]}' ;;
  "t2 https://api.github.com/repos/two/b/topics") echo '{"names":["kheona-skill","kheona-lib"]}' ;;
  *) echo "fake curl: unexpected $tok $url" >&2; exit 22 ;;
esac
FAKE
chmod +x "$T/curlbin/curl"
echo '{"one":"t1","two":"t2"}' > "$T/tokens.json"
check "App tokens: each installation, topics per repository" "$(PATH="$T/curlbin:$T/nogh:$PATH" KSKILL_APP_TOKENS="$T/tokens.json" bash "$REPOS" --topic kheona-skill)" $'one/a\ntwo/b'
check "App tokens: --forks only"                             "$(PATH="$T/curlbin:$T/nogh:$PATH" KSKILL_APP_TOKENS="$T/tokens.json" bash "$REPOS" --topic kheona-lib --forks only)" 'two/b'

# Accepted spellings (scripts/kskill-topics.json): kskill is kheona-skill, klib is kheona-lib; nothing else is.
cat > "$T/aliases.json" <<'JSON'
[{"full_name":"o/long","fork":false,"archived":false,"topics":["kheona-skill","kheona-lib"]},
 {"full_name":"o/short","fork":false,"archived":false,"topics":["kskill","klib"]},
 {"full_name":"o/other","fork":false,"archived":false,"topics":["kheona","lib","skill"]}]
JSON
check "--topic kheona-skill also keeps kskill"                "$(PATH="$T/nogh:$PATH" bash "$REPOS" --from "$T/aliases.json" --topic kheona-skill)" $'o/long\no/short'
check "--topic kheona-lib also keeps klib"                    "$(PATH="$T/nogh:$PATH" bash "$REPOS" --from "$T/aliases.json" --topic kheona-lib)" $'o/long\no/short'
check "a topic without aliases matches itself only"           "$(PATH="$T/nogh:$PATH" bash "$REPOS" --from "$T/aliases.json" --topic lib)" 'o/other'

echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
