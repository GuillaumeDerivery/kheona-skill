#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline tests for scripts/kskill-repo-settings.sh and config/repo-settings.json, against a fake `gh`
# that answers reads from fixtures and logs writes. No network, no credentials.
set -uo pipefail
export KSKILL_REPO=owner/kheona-skill KSKILL_BOT='example-app[bot]'
HERE=$(cd "$(dirname "$0")/.." && pwd)
SETTINGS="$HERE/scripts/kskill-repo-settings.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
check() { # check <name> <output> <expected output>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"
  else failn=$((failn+1)); echo "FAIL $1"; printf '     got:  %s\n' "${2//$'\n'/$'\n'           }"; printf '     want: %s\n' "${3//$'\n'/$'\n'           }"; fi
}

# ---- fake gh: `gh api [-X M] <path> [--input -]`. GET answers $FIX/<path, / replaced by _>.json, else HTTP 404
# ($FIX/<path>.403 makes it HTTP 403); a write is appended to $LOG as "<M> <path> <body>" and fails when
# $FIX/<path>.refuse exists. ----
FIX="$T/fix"; LOG="$T/writes.log"; mkdir -p "$FIX" "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = api ] || { echo "fake gh: only api" >&2; exit 1; }
shift; method=GET path= input=false
while [ $# -gt 0 ]; do case "$1" in -X) method=$2; shift 2 ;; --input) input=true; shift 2 ;; -H) shift 2 ;; *) path=$1; shift ;; esac; done
f="$FAKE_FIX/$(printf '%s' "$path" | tr '/' '_')"
if [ "$method" != GET ]; then
  body=""; [ "$input" = true ] && body=$(jq -cS . 2>/dev/null)
  echo "$method $path${body:+ $body}" >> "$FAKE_LOG"
  [ -e "$f.refuse" ] && { echo "gh: Resource not accessible (HTTP 403)" >&2; exit 1; }
  exit 0
fi
[ -e "$f.403" ] && { echo "gh: Must have admin rights (HTTP 403)" >&2; exit 1; }
[ -f "$f.json" ] && { cat "$f.json"; exit 0; }
echo "gh: Not Found (HTTP 404)" >&2; exit 1
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" FAKE_FIX="$FIX" FAKE_LOG="$LOG"
fix() { printf '%s' "$2" > "$FIX/$(printf '%s' "$1" | tr '/' '_').json"; }
kj() { fix "repos/$1/contents/.kheona.json" "{\"content\":\"$(printf '%s' "$2" | base64 | tr -d '\n')\"}"; }
# good <repo> [fork] [topics]: a repository whose every setting is the declared default.
good() {
  fix "repos/$1" "{\"full_name\":\"$1\",\"fork\":${2:-false},\"topics\":${3:-[\"kheona-skill\"]},\"allow_squash_merge\":true,\"allow_merge_commit\":${2:-false},\"allow_rebase_merge\":false,\"delete_branch_on_merge\":true,\"allow_update_branch\":true,\"has_wiki\":false}"
  fix "repos/$1/actions/permissions" '{"enabled":true,"allowed_actions":"all"}'
  fix "repos/$1/actions/permissions/workflow" '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
  # Dependabot alerts off: no fixture, so HTTP 404 (GitHub's answer when they are off).
  fix "repos/$1/automated-security-fixes" '{"enabled":false,"paused":false}'
  fix "repos/$1/labels?per_page=100" "$(jq -c '[.settings[] | select(.api == "label") | .label]' "$HERE/config/repo-settings.json")"
  fix "repos/$1/actions/variables?per_page=100" '{"total_count":1,"variables":[{"name":"KSKILL_BOT","value":"example-app[bot]"}]}'
}
run() { : > "$LOG"; bash "$SETTINGS" "$@"; }
j() { jq -c "$1"; }

# The declaration itself.
check "the declaration parses, every entry has key, api, value (a variable: variable and derive) and why" \
  "$(jq -c '.settings as $s | [$s[] | select(.key and .api and (if .api == "variable" then (.variable and .derive) else has("value") end) and (.why | length > 0))] | length == ($s | length)' "$HERE/config/repo-settings.json")" true
check "no setting that needs a paid plan is declared" \
  "$(jq -r '[.settings[].key] | map(select(test("protection|ruleset|allow_auto_merge|required_"))) | length' "$HERE/config/repo-settings.json")" 0

# A repository with the defaults: OK, exit 0, nothing written.
good org/a; kj org/a '{"role":"project"}'
out=$(run org/a --json); rc=$?
check "defaults: ok"                    "$(j '[.ok, .drift, .errors, .role, .fork]' <<<"$out")" '[true,[],[],"project",false]'
check "defaults: exit 0"                "$rc" 0
check "defaults: every declared key read" "$(j '[.settings[] | select(.have == null)] | length' <<<"$out")" 0
out=$(run org/a --apply --json)
check "defaults: --apply writes nothing" "$(cat "$LOG")" ''

# Drift in every API, then --apply.
good org/b
fix repos/org/b '{"full_name":"org/b","fork":false,"topics":["kheona-skill"],"allow_squash_merge":false,"allow_merge_commit":true,"allow_rebase_merge":true,"delete_branch_on_merge":false,"allow_update_branch":false,"has_wiki":true}'
fix repos/org/b/actions/permissions/workflow '{"default_workflow_permissions":"write","can_approve_pull_request_reviews":true}'
fix repos/org/b/vulnerability-alerts ''
fix repos/org/b/automated-security-fixes '{"enabled":true,"paused":false}'
out=$(run org/b --json); rc=$?
check "drift: a false value is read as false, not as missing" \
  "$(j '[.settings[] | select(.key == "allow_update_branch" or .key == "has_wiki") | .have]' <<<"$out")" '[false,true]'
check "drift: listed"                   "$(j .drift <<<"$out")" \
  '["allow_squash_merge","allow_merge_commit","allow_rebase_merge","delete_branch_on_merge","allow_update_branch","has_wiki","default_workflow_permissions","can_approve_pull_request_reviews","vulnerability_alerts","automated_security_fixes"]'
check "drift: any repository but a fork is squash only (release-please reads one commit per PR)" \
  "$(j '[.settings[] | select(.key == "allow_merge_commit" or .key == "allow_rebase_merge") | .want]' <<<"$out")" '[false,false]'
check "drift: exit 1"                   "$rc" 1
check "drift: nothing written without --apply" "$(cat "$LOG")" ''
out=$(run org/b --apply --json); rc=$?
check "--apply: one write per API, Dependabot's security updates off before its alerts" "$(cat "$LOG")" \
'PATCH repos/org/b {"allow_merge_commit":false,"allow_rebase_merge":false,"allow_squash_merge":true,"allow_update_branch":true,"delete_branch_on_merge":true,"has_wiki":false}
PUT repos/org/b/actions/permissions/workflow {"can_approve_pull_request_reviews":false,"default_workflow_permissions":"read"}
DELETE repos/org/b/automated-security-fixes
DELETE repos/org/b/vulnerability-alerts'
check "--apply: everything applied, ok, exit 0" "$(j '[.ok, (.applied | length)]' <<<"$out") $rc" '[true,10] 0'
# Turned on by an override (with its why): the alerts first, GitHub refuses the security updates without them.
good org/v; kj org/v '{"settings":{"vulnerability_alerts":{"value":true,"why":"t"},"automated_security_fixes":{"value":true,"why":"t"}}}'
out=$(run org/v --apply --json)
check "--apply: turning Dependabot on, alerts before security updates" "$(cat "$LOG")" \
'PUT repos/org/v/vulnerability-alerts
PUT repos/org/v/automated-security-fixes'

# Labels: one read; a missing one is created with its colour and description, never edited or deleted.
good org/l; fix "repos/org/l/labels?per_page=100" '[{"name":"size: small","color":"000000"},{"name":"bug"}]'
out=$(run org/l --json)
check "labels: the missing ones drift, an existing one (any colour) is ok" \
  "$(j '[.settings[] | select(.api == "label") | select(.ok | not) | .key] | length' <<<"$out") $(j '[.settings[] | select(.key == "label_size_small") | .ok][0]' <<<"$out")" \
  "$(( $(jq '[.settings[] | select(.api == "label")] | length' "$HERE/config/repo-settings.json") - 1 )) true"
out=$(run org/l --apply --json)
check "labels: --apply creates each missing one" "$(grep -c '^POST repos/org/l/labels ' "$LOG") $(grep -c '"name":"size: small"' "$LOG")" \
  "$(( $(jq '[.settings[] | select(.api == "label")] | length' "$HERE/config/repo-settings.json") - 1 )) 0"
check "labels: with its colour and description" "$(grep -c '^POST repos/org/l/labels {"color":"d93f0b","description":"[^"]*","name":"size: large"}$' "$LOG")" 1
rm -f "$FIX/repos_org_l_labels?per_page=100.json"
out=$(run org/l --json)
check "labels unreadable: an error, not a drift" "$(j '[(.drift | map(select(startswith("label_"))) | length), [.errors[].key]]' <<<"$out")" '[0,["labels"]]'

# Roles and forks.
good me/lib; kj me/lib '{"role":"library"}'
fix repos/me/lib '{"full_name":"me/lib","fork":false,"topics":["kheona-skill"],"allow_squash_merge":true,"allow_merge_commit":true,"allow_rebase_merge":true,"delete_branch_on_merge":true,"allow_update_branch":true,"has_wiki":false}'
out=$(run me/lib --json)
check "library: squash only"            "$(j '[.drift, ([.settings[] | select(.key == "allow_merge_commit")][0].source)]' <<<"$out")" '[["allow_merge_commit","allow_rebase_merge"],"default"]'
good org/fork true; kj org/fork '{"role":"template"}'
fix repos/org/fork '{"full_name":"org/fork","fork":true,"topics":["kheona-skill"],"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":true,"delete_branch_on_merge":true,"allow_update_branch":true,"has_wiki":false}'
out=$(run org/fork --json)
check "fork: merge commits on, for the upstream sync PR" "$(j '[.drift, ([.settings[] | select(.key == "allow_merge_commit")][0] | .want, .source)]' <<<"$out")" '[["allow_merge_commit"],true,"fork"]'

# .kheona.json overrides.
good org/c; kj org/c '{"role":"app","settings":{"can_approve_pull_request_reviews":{"value":true,"why":"a local workflow opens PRs with GITHUB_TOKEN"},"has_wiki":{"value":null,"why":"the wiki is used"},"allow_update_branch":{"value":false}}}'
fix repos/org/c/actions/permissions/workflow '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":true}'
fix repos/org/c '{"full_name":"org/c","fork":false,"topics":["kheona-skill"],"allow_squash_merge":true,"delete_branch_on_merge":true,"allow_update_branch":false,"has_wiki":true}'
out=$(run org/c --json)
check "override: a value with its why wins" "$(j '[.settings[] | select(.key == "can_approve_pull_request_reviews") | .want, .source, .ok]' <<<"$out")" '[true,".kheona.json",true]'
check "override: null leaves the key unmanaged" "$(j '[.settings[] | select(.key == "has_wiki")] | length' <<<"$out")" 0
check "override: without a why it is refused, the default stays" "$(j '[.drift, [.errors[].key]]' <<<"$out")" '[["allow_update_branch"],["allow_update_branch"]]'

# Topic: read-only; kheona-skill itself is exempt.
good org/d false '[]'
out=$(run org/d --apply --json); rc=$?
check "topic missing: drift, never written" "$(j '[.drift, .applied, .ok]' <<<"$out")$(cat "$LOG")" '[["topic_kheona_skill"],[],false]'
check "topic missing: exit 1"           "$rc" 1
good org/e false '["kskill"]'
out=$(run org/e --json); rc=$?
check "topic kskill counts as kheona-skill: no drift" "$(j '[.drift, .ok]' <<<"$out")" '[[],true]'
good owner/kheona-skill false '[]'; kj owner/kheona-skill '{"role":"library"}'
out=$(run owner/kheona-skill --json)
check "kheona-skill carries no topic and is not asked to" "$(j '[.ok, ([.settings[].key] | index("topic_kheona_skill"))]' <<<"$out")" '[true,null]'

# Actions variables: derived from .kheona.json, "false" where a workflow is switched off, absent otherwise.
good owner/tpl; kj owner/tpl '{"role":"template","workflows":{"cd":{"templateRepository":"owner/tpl","staging":false,"prod":false}}}'
out=$(run owner/tpl --json); rc=$?
check "variables: a template switches the deploys off; no CI on release-please's PR" \
  "$(j '[.settings[] | select(.api == "variable" and .key != "variable_bot") | {(.key): .want}] | add' <<<"$out") $(j .drift <<<"$out") $rc" \
  '{"variable_cd_staging":"false","variable_cd_prod":"false","variable_release_pr":"","variable_release_pr_ci":"false","variable_ci_on_push":"","variable_dist_rebuild":"","variable_automerge":""} ["variable_cd_staging","variable_cd_prod","variable_release_pr_ci"] 1'
out=$(run owner/tpl --apply --json); rc=$?
check "variables: --apply creates the missing ones" "$(cat "$LOG") $(j .ok <<<"$out") $rc" \
'POST repos/owner/tpl/actions/variables {"name":"KSKILL_CD_STAGING","value":"false"}
POST repos/owner/tpl/actions/variables {"name":"KSKILL_CD_PROD","value":"false"}
POST repos/owner/tpl/actions/variables {"name":"KSKILL_RELEASE_PR_CI","value":"false"} true 0'
# Its fork deploys: the inherited templateRepository names the parent, the fork has its own targets.
good org/tfork true; kj org/tfork '{"role":"template","workflows":{"cd":{"templateRepository":"owner/tpl","staging":false,"prod":{"cluster":"c"}}}}'
fix "repos/org/tfork/actions/variables?per_page=100" '{"variables":[{"name":"KSKILL_CD_PROD","value":"false"},{"name":"KSKILL_CD_STAGING","value":"no"},{"name":"OTHER","value":"x"},{"name":"KSKILL_BOT","value":"example-app[bot]"}]}'
out=$(run org/tfork --apply --json)
check "variables: a fork's own prod deploys; stale ones are deleted or corrected" \
  "$(j '[.settings[] | select(.api == "variable" and .key != "variable_bot" and .want != "") | .key]' <<<"$out") $(grep variables "$LOG")" \
  '["variable_cd_staging","variable_release_pr_ci"] PATCH repos/org/tfork/actions/variables/KSKILL_CD_STAGING {"name":"KSKILL_CD_STAGING","value":"false"}
DELETE repos/org/tfork/actions/variables/KSKILL_CD_PROD
POST repos/org/tfork/actions/variables {"name":"KSKILL_RELEASE_PR_CI","value":"false"}'
good org/sw; kj org/sw '{"role":"project","workflows":{"ci":{"runOnPush":false},"automerge":{"enabled":false},"cd":{"staging":{"cluster":"c"},"prod":{"cluster":"c"},"enabled":true}}}'
out=$(run org/sw --json)
check "variables: the automerge switch; runOnPush is retired (no variable); a deploying project keeps its deploys" \
  "$(j '[.settings[] | select(.api == "variable" and .key != "variable_bot" and .want != "") | .variable]' <<<"$out")" '["KSKILL_RELEASE_PR_CI","KSKILL_AUTOMERGE"]'
good org/cdoff; kj org/cdoff '{"role":"project","workflows":{"cd":{"enabled":false}}}'
check "variables: workflows.cd.enabled false switches the deploys off" \
  "$(run org/cdoff --json | j '[.settings[] | select(.api == "variable" and .key != "variable_bot" and .want != "") | .variable]')" '["KSKILL_CD_STAGING","KSKILL_CD_PROD","KSKILL_RELEASE_PR_CI"]'
good me/lib2; kj me/lib2 '{"role":"library"}'
check "variables: a library without workflows.cd gets none" "$(run me/lib2 --json | j '[.settings[] | select(.api == "variable" and .key != "variable_bot" and .want != "")] | length')" 0
good me/lib3; kj me/lib3 '{"role":"library","workflows":{"distRebuild":{}}}'
check "variables: workflows.distRebuild switches the PR's dist rebuild on" "$(run me/lib3 --json | j '[.settings[] | select(.api == "variable" and .key != "variable_bot" and .want != "") | "\(.variable)=\(.want)"]')" '["KSKILL_DIST_REBUILD=true"]'
good org/nv; rm -f "$FIX/repos_org_nv_actions_variables?per_page=100.json"; kj org/nv '{"role":"template","workflows":{"cd":{"templateRepository":"org/nv"}}}'
out=$(run org/nv --json)
check "variables unreadable: one error, not a drift" "$(j '[(.drift | map(select(startswith("variable_"))) | length), [.errors[].key]]' <<<"$out")" '[0,["variables"]]'

# KSKILL_BOT: written from the environment, no default; unset, it is left alone (never deleted).
good org/bot; fix "repos/org/bot/actions/variables?per_page=100" '{"variables":[{"name":"KSKILL_BOT","value":"old-app[bot]"}]}'
out=$(KSKILL_BOT='new-app[bot]' run org/bot --apply --json)
check "bot variable: corrected from the environment" "$(grep KSKILL_BOT "$LOG")" \
  'PATCH repos/org/bot/actions/variables/KSKILL_BOT {"name":"KSKILL_BOT","value":"new-app[bot]"}'
: > "$LOG"; env -u KSKILL_BOT bash "$SETTINGS" org/bot --apply --json >/dev/null 2>&1
check "bot variable: unset in the environment, never deleted" "$(grep -c KSKILL_BOT "$LOG")" 0

# Unreadable and refused.
good org/e; touch "$FIX/repos_org_e_actions_permissions_workflow.403"
out=$(run org/e --json); rc=$?
check "unreadable: an error, not a drift" "$(j '[.drift, [.errors[].key], .ok]' <<<"$out") $rc" '[[],["default_workflow_permissions","can_approve_pull_request_reviews"],false] 1'
good org/f; fix repos/org/f '{"full_name":"org/f","fork":false,"topics":["kheona-skill"],"allow_squash_merge":true,"delete_branch_on_merge":true,"allow_update_branch":true,"has_wiki":true}'
touch "$FIX/repos_org_f.refuse"
out=$(run org/f --apply --json); rc=$?
check "refused write: reported, not applied" "$(j '[.applied, [.errors[].key], .ok]' <<<"$out") $rc" '[[],["has_wiki"],false] 1'
out=$(run org/missing --json); rc=$?
check "unknown repository: an error document, exit 1" "$(j '[.ok, (.errors | length)]' <<<"$out") $rc" '[false,1] 1'
out=$(run org/a); check "text output ends with the verdict" "$(tail -1 <<<"$out")" 'org/a: repository settings OK'
bash "$SETTINGS" >/dev/null 2>&1; check "no repository: usage error" "$?" 64
bash "$SETTINGS" org/a --nope >/dev/null 2>&1; check "unknown flag: usage error" "$?" 64

# One definition: no other script, workflow or tool writes repository settings itself.
others=$(cd "$HERE" && grep -rlE -- '-X (PATCH|PUT|DELETE)[^|]*repos/[^ ]*(/actions/permissions|/vulnerability-alerts|/automated-security-fixes)|delete_branch_on_merge=|allow_squash_merge=' scripts tools doctor .github/workflows templates/.github 2>/dev/null | grep -v '^scripts/kskill-repo-settings.sh$' || true)
check "no other file writes repository settings" "$others" ''

echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
