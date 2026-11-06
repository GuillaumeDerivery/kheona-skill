#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline test of kskill-sync-upstream.yml's parent side ("Notify the forks"): the step's own script, extracted from
# the template, run against a fake gh. A private fork under another owner is invisible to GET repos/<parent>/forks
# with the parent owner's token: it must be found through that owner's installation, by its parent.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
check() { # check <name> <output> <grep -E pattern> [absent]
  if { [ "${4:-}" = absent ] && ! grep -qE "$3" <<<"$2"; } || { [ "${4:-}" != absent ] && grep -qE "$3" <<<"$2"; }; then
    pass=$((pass+1)); echo "ok   $1"
  else failn=$((failn+1)); echo "FAIL $1 (pattern $3${4:+, $4})"; printf '     %s\n' "${2//$'\n'/$'\n'     }"; fi
}

# The step's script: the `run: |` block after `- name: Notify the forks`, up to the next blank line, de-indented.
awk '/- name: Notify the forks/ { f = 1 } f && /run: \|/ { r = 1; next } r && /^$/ { exit } r { sub(/^          /, ""); print }' \
  "$HERE/.github/workflows/kskill-sync-upstream.yml" > "$T/notify.sh"
[ -s "$T/notify.sh" ] || { echo "FAIL could not extract the Notify the forks script"; exit 1; }

# Fake gh: the token in use is the owner GH_REPO names (as the kskill-app-tokens.mjs wrapper does), else the parent's.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
owner=${GH_REPO%%/*}; [ -n "$owner" ] || owner=${GITHUB_REPOSITORY%%/*}
jqx=.; path=""; args=("$@")
for ((i = 1; i < ${#args[@]}; i++)); do case "${args[i]}" in --jq) jqx=${args[i+1]}; i=$((i+1)) ;; -f) i=$((i+1)) ;; -*) ;; *) [ -n "$path" ] || path=${args[i]} ;; esac; done
case "$path" in repos/*) owner=$(cut -d/ -f2 <<<"$path") ;; esac
if [[ "$path" == */dispatches ]]; then p=${path#repos/}; echo "${p%/dispatches}" >> "$FAKE/dispatched"; exit 0; fi
f="$FAKE/$owner/$(tr '/?' '__' <<<"$path").json"
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
jq -r "$jqx" "$f"
GH
chmod +x "$T/bin/gh"
FAKE="$T/fake"; mkdir -p "$FAKE/parentorg" "$FAKE/otherorg" "$FAKE/thirdorg"
put() { mkdir -p "$(dirname "$FAKE/$1")"; printf '%s' "$2" > "$FAKE/$1"; }
# The parent's own token sees one public fork only.
put parentorg/repos_parentorg_tpl_forks.json '[{"full_name":"parentorg/tpl-fork"}]'
put parentorg/installation_repositories.json '{"repositories":[{"full_name":"parentorg/tpl","fork":false,"archived":false},{"full_name":"parentorg/tpl-fork","fork":true,"archived":false}]}'
put parentorg/repos_parentorg_tpl-fork.json '{"parent":{"full_name":"parentorg/tpl"}}'
# Another owner: a private fork of tpl, a fork of something else, an archived fork of tpl.
put otherorg/installation_repositories.json '{"repositories":[{"full_name":"otherorg/tpl","fork":true,"archived":false},{"full_name":"otherorg/elsewhere","fork":true,"archived":false},{"full_name":"otherorg/old","fork":true,"archived":true},{"full_name":"otherorg/app","fork":false,"archived":false}]}'
put otherorg/repos_otherorg_tpl.json '{"parent":{"full_name":"ParentOrg/tpl"}}'
put otherorg/repos_otherorg_elsewhere.json '{"parent":{"full_name":"someone/else"}}'
put otherorg/repos_otherorg_old.json '{"parent":{"full_name":"parentorg/tpl"}}'
printf '{"parentorg":"t1","otherorg":"t2","thirdorg":"t3"}' > "$T/tokens.json"

run() { (cd "$T" && PATH="$T/bin:$PATH" FAKE="$FAKE" HAS_APP=true SHA=abc GITHUB_REPOSITORY=parentorg/tpl GITHUB_STEP_SUMMARY=/dev/null \
  KSKILL_APP_TOKENS="$T/tokens.json" bash -e notify.sh 2>&1); }
out=$(run); sent=$(sort "$FAKE/dispatched" 2>/dev/null)
check "a private fork under another owner is notified"   "$sent" '^otherorg/tpl$'
check "the fork the parent's token sees, once"            "$(grep -c '^parentorg/tpl-fork$' <<<"$sent")" '^1$'
check "a fork of another repository is not"               "$sent" 'otherorg/elsewhere' absent
check "an archived fork is not"                           "$sent" 'otherorg/old' absent
check "an owner whose listing fails: warned, others kept" "$out" "Could not list the repositories of thirdorg"
check "exactly two notices"                               "$(wc -l <<<"$sent" | tr -d ' ')" '^2$'

rm -f "$FAKE/dispatched" "$FAKE/otherorg/installation_repositories.json" "$FAKE/parentorg/repos_parentorg_tpl_forks.json"
put parentorg/installation_repositories.json '{"repositories":[]}'
out=$(run)
check "no fork anywhere: said so, nothing sent"           "$out$(cat "$FAKE/dispatched" 2>/dev/null)" '^No fork to notify\.$|No fork to notify\.'

echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
