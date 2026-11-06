#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# the repository settings every repository with the topic kheona-skill must have, compared with GitHub's and,
# with --apply, written there. The one definition: the template sync applies it (sync-templates.yml), the map
# collector reads its --json  and the doctor's remedy runs it with --apply.
#
# Usage: kskill-repo-settings.sh <owner/repo> [--apply] [--json] [--declaration <file>]
#   --apply        write every drifted setting (one PATCH per API), then report what was applied.
#   --json         print one JSON document instead of text lines, same exit code:
#                    { "repo", "fork": bool, "role": string|null, "ok": bool,
#                      "settings": [{ "key", "api", "want", "have" (null: unreadable), "ok": bool, "source", "why",
#                                     "readOnly": bool, "applied": bool, "variable" (api variable only) }],
#                      "drift": ["<key>"], "applied": ["<key>"], "errors": [{ "key", "message" }] }
#                  source: "default", "role:<role>", "fork" (the declaration entry that set it) or ".kheona.json".
#   --declaration  the declaration to read (default: config/repo-settings.json next to this script; tests).
# Labels (`api: label`): a declared label must exist; --apply creates a missing one, never edits or deletes one.
# Actions variables (`api: variable`): `variable` names it, `derive` is a jq expression over the repository's .kheona.json
# ($repo, $fork bound) giving its value; "" means the variable must not exist (--apply deletes it). They let a template
# skip a switched-off job in its `if:`, before any runner starts (`vars.<NAME>`), which `.kheona.json` cannot do.
# What is wanted: config/repo-settings.json, entries in order (a `when` narrows one to forks or roles), then the
# repository's .kheona.json `settings` ({"<key>": {"value": <v>, "why": "..."}}; value null: not managed there; an
# override without a `why` is refused, reported as an error, and the default stays).
# Free plans: every setting here is available on a free plan, private repositories included. GitHub settings that
# need a paid plan (branch protection, rulesets, native auto-merge) are never read or written.
# Env: GH_TOKEN, or `gh` signed in; --apply needs admin on the repository (the automation App: Administration write).
# Exit: 0 when nothing drifts (after --apply: when everything drifted was written), 1 otherwise, 64 on usage.
set -uo pipefail

usage() { sed -n '6,6p' "$0" | sed 's/^# //' >&2; exit 64; }
REPO="" APPLY=false JSON=false DECL=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --json) JSON=true; shift ;;
    --declaration) DECL=${2:?--declaration needs a file}; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "kskill-repo-settings.sh: unknown argument $1" >&2; usage ;;
    *) [ -z "$REPO" ] || usage; REPO=$1; shift ;;
  esac
done
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[ -n "$DECL" ] || DECL="$(cd "$(dirname "$0")/.." && pwd)/config/repo-settings.json"
SKILL_REPO=${KSKILL_REPO:-}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# api_get <path>: the body on stdout, exit 0; exit 4 on HTTP 404; exit 1 on anything else (stderr kept in $TMP/err).
api_get() {
  if gh api "$1" 2>"$TMP/err"; then return 0; fi
  grep -q 'HTTP 404' "$TMP/err" && return 4
  return 1
}
errors='[]'
err() { errors=$(jq -c --arg k "$1" --arg m "$2" '. + [{key: $k, message: $m}]' <<<"$errors"); }

if ! meta=$(api_get "repos/$REPO"); then
  msg="GitHub does not answer for $REPO ($(tr -d '\n' < "$TMP/err" | cut -c1-200))"
  if [ "$JSON" = true ]; then
    jq -n --arg r "$REPO" --arg m "$msg" '{repo: $r, fork: null, role: null, ok: false, settings: [], drift: [], applied: [], errors: [{key: null, message: $m}]}'
  else echo "error: $msg" >&2; fi
  exit 1
fi
fork=$(jq '.fork == true' <<<"$meta")
kheona='{}'
if kj=$(api_get "repos/$REPO/contents/.kheona.json"); then
  kheona=$(jq -r '.content // "" | gsub("\\s"; "") | @base64d' <<<"$kj" 2>/dev/null | jq -c 'if type == "object" then . else {} end' 2>/dev/null) ||
    { kheona='{}'; err .kheona.json "not valid JSON: its settings overrides and role are ignored"; }
fi
role=$(jq -r '.role // empty' <<<"$kheona")

# Actions variables: each `derive` evaluated over .kheona.json becomes the entry's value (a string; "" = must not exist).
decl=$(cat "$DECL" 2>/dev/null) || { echo "kskill-repo-settings.sh: cannot read $DECL" >&2; exit 64; }
for i in $(jq -r '.settings | to_entries[] | select(.value.api == "variable") | .key' <<<"$decl" 2>/dev/null); do
  expr=$(jq -r --argjson i "$i" '.settings[$i].derive // "\"\""' <<<"$decl")
  if v=$(jq -r --arg repo "$REPO" --argjson fork "$fork" "$expr" <<<"$kheona" 2>/dev/null) && [[ "$v" != *$'\n'* ]]; then
    decl=$(jq -c --argjson i "$i" --arg v "$v" '.settings[$i].value = $v' <<<"$decl")
  else
    err "$(jq -r --argjson i "$i" '.settings[$i].key' <<<"$decl")" "derive does not give one string: the variable is not managed"
    decl=$(jq -c --argjson i "$i" '.settings[$i].value = null' <<<"$decl")
  fi
done

# The wanted settings: the declaration's entries that apply, the last one per key winning, then the overrides.
# shellcheck disable=SC2016  # why: the $names are jq variables
want=$(jq -c --argjson fork "$fork" --arg role "$role" --argjson kj "$kheona" '
  [.settings[] | select((.when.fork == null or .when.fork == $fork) and (.when.role == null or ((.when.role | index($role)) != null)))
   | . + {source: (if .when.fork then "fork" elif .when.role then "role:\($role)" else "default" end)}]
  | reduce .[] as $e ({}; .[$e.key] = $e) | [.[]]
  | map(. as $e | ($kj.settings[$e.key] // null) as $o
      | if $o == null or ($o | type) != "object" or ($o | has("value") | not) then $e
        elif (($o.why // "") | length) == 0 then $e + {refused: true}
        else $e + {value: $o.value, why: $o.why, source: ".kheona.json"} end)
  | map(select(.value != null))' <<<"$decl") || { echo "kskill-repo-settings.sh: cannot read $DECL" >&2; exit 64; }
for k in $(jq -r '.[] | select(.refused) | .key' <<<"$want"); do
  err "$k" ".kheona.json settings.$k has no \`why\`: the override is refused, the declared value stays"
done

# What GitHub has, one read per API that is used.
have='{}'
put() { have=$(jq -c --arg k "$1" --argjson v "$2" '.[$k] = $v' <<<"$have"); }
apis=$(jq -r '[.[].api] | unique | .[]' <<<"$want")
for api in $apis; do
  keys=$(jq -r --arg a "$api" '.[] | select(.api == $a) | .key' <<<"$want")
  case "$api" in
    repo) for k in $keys; do put "$k" "$(jq --arg k "$k" '.[$k]' <<<"$meta")"; done ;;
    topic)
      for k in $keys; do
        t=$(jq -r --arg k "$k" '.[] | select(.key == $k) | .topic' <<<"$want")
        # Any accepted spelling of the topic counts (scripts/kskill-topics.json).
        names=$(jq -c --arg t "$t" '.[$t] // [$t]' "$(cd "$(dirname "$0")" && pwd)/kskill-topics.json")
        put "$k" "$(jq --argjson n "$names" '(.topics // []) as $ts | $n | any(. as $x | $ts | index($x) != null)' <<<"$meta")"
      done ;;
    actions)
      if body=$(api_get "repos/$REPO/actions/permissions"); then put actions_enabled "$(jq '.enabled' <<<"$body")"
      else err actions_enabled "cannot read the Actions permissions (admin needed)"; fi ;;
    workflow)
      if body=$(api_get "repos/$REPO/actions/permissions/workflow"); then
        for k in $keys; do put "$k" "$(jq --arg k "$k" '.[$k]' <<<"$body")"; done
      else for k in $keys; do err "$k" "cannot read the workflow permissions (admin needed)"; done; fi ;;
    vulnerability_alerts)
      # 204 enabled, 404 disabled.
      api_get "repos/$REPO/vulnerability-alerts" >/dev/null; rc=$?
      case $rc in 0) put vulnerability_alerts true ;; 4) put vulnerability_alerts false ;; *) err vulnerability_alerts "cannot read the Dependabot alerts setting" ;; esac ;;
    label)
      # Every label of the repository in one read (paginated): a declared label is there or not.
      if gh api --paginate "repos/$REPO/labels?per_page=100" > "$TMP/labels" 2>"$TMP/err" && names=$(jq -s 'add // [] | map(.name)' "$TMP/labels" 2>/dev/null); then
        for k in $keys; do
          put "$k" "$(jq --arg k "$k" --argjson names "$names" '(.[] | select(.key == $k) | .label.name) as $n | $names | index($n) != null' <<<"$want")"
        done
      else err labels "cannot read the labels"; fi ;;
    variable)
      # Every Actions variable of the repository in one read (paginated); a missing one reads as "".
      if gh api --paginate "repos/$REPO/actions/variables?per_page=100" > "$TMP/vars" 2>"$TMP/err" &&
        present=$(jq -s 'map(.variables // []) | add // [] | map({(.name): .value}) | add // {}' "$TMP/vars" 2>/dev/null); then
        for k in $keys; do
          put "$k" "$(jq -c --arg k "$k" --argjson p "$present" '(.[] | select(.key == $k) | .variable) as $n | $p[$n] // ""' <<<"$want")"
        done
      else err variables "cannot read the Actions variables"; fi ;;
    automated_security_fixes)
      api_get "repos/$REPO/automated-security-fixes" > "$TMP/asf"; rc=$?
      case $rc in 0) put automated_security_fixes "$(jq '.enabled // false' "$TMP/asf")" ;; 4) put automated_security_fixes false ;;
        *) err automated_security_fixes "cannot read the Dependabot security updates setting" ;; esac ;;
    *) for k in $keys; do err "$k" "unknown api $api in the declaration"; done ;;
  esac
done

# kheona-skill is the source of the topic rule, and carries no topic.
# shellcheck disable=SC2016
rows=$(jq -c --argjson have "$have" --arg self "$([ "$REPO" = "$SKILL_REPO" ] && echo true)" '
  map(select(.api != "topic" or $self != "true"))
  | map(. as $e | {key, api, want: .value, have: (if ($have | has($e.key)) then $have[$e.key] else null end), source, why,
         readOnly: (.check == "read-only"), applied: false} + (if .variable then {variable} else {} end))
  | map(. + {ok: (.have != null and .have == .want)})' <<<"$want")

if [ "$APPLY" = true ]; then
  # write <key...>: marks them applied.
  mark() { for k in "$@"; do rows=$(jq -c --arg k "$k" 'map(if .key == $k then . + {applied: true} else . end)' <<<"$rows"); done; }
  drifted() { jq -r --arg a "$1" '.[] | select(.api == $a and (.ok | not) and (.readOnly | not) and .have != null) | .key' <<<"$rows"; }
  body_of() { jq -c --arg a "$1" '[.[] | select(.api == $a and (.ok | not) and (.readOnly | not) and .have != null) | {(.key): .want}] | add // {}' <<<"$rows"; }
  write() { # write <method> <path> [body]
    if [ -n "${3:-}" ]; then gh api -X "$1" "$2" --input - <<<"$3" >/dev/null 2>"$TMP/err"; else gh api -X "$1" "$2" >/dev/null 2>"$TMP/err"; fi
  }
  keys=$(drifted repo)
  if [ -n "$keys" ]; then
    # shellcheck disable=SC2086  # why: one key per word
    if write PATCH "repos/$REPO" "$(body_of repo)"; then mark $keys; else for k in $keys; do err "$k" "PATCH refused: $(tr -d '\n' < "$TMP/err" | cut -c1-200)"; done; fi
  fi
  if [ -n "$(drifted actions)" ]; then
    if write PUT "repos/$REPO/actions/permissions" "$(jq -c '{enabled: .actions_enabled}' <<<"$(body_of actions)")"; then mark actions_enabled
    else err actions_enabled "PUT refused: $(tr -d '\n' < "$TMP/err" | cut -c1-200)"; fi
  fi
  keys=$(drifted workflow)
  if [ -n "$keys" ]; then
    # shellcheck disable=SC2086
    if write PUT "repos/$REPO/actions/permissions/workflow" "$(body_of workflow)"; then mark $keys; else for k in $keys; do err "$k" "PUT refused: $(tr -d '\n' < "$TMP/err" | cut -c1-200)"; done; fi
  fi
  # A missing label is created; a label is never edited or deleted here.
  for k in $(drifted label); do
    [ "$(jq -r --arg k "$k" '.[] | select(.key == $k) | .want' <<<"$rows")" = true ] || continue
    if write POST "repos/$REPO/labels" "$(jq -c --arg k "$k" '.[] | select(.key == $k) | .label' <<<"$want")"; then mark "$k"
    else err "$k" "POST refused: $(tr -d '\n' < "$TMP/err" | cut -c1-200)"; fi
  done
  # An Actions variable: created, updated, or deleted when it must not exist (the App needs Variables write).
  for k in $(drifted variable); do
    name=$(jq -r --arg k "$k" '.[] | select(.key == $k) | .variable' <<<"$want")
    value=$(jq -r --arg k "$k" '.[] | select(.key == $k) | .want' <<<"$rows")
    have_v=$(jq -r --arg k "$k" '.[] | select(.key == $k) | .have' <<<"$rows")
    body=$(jq -cn --arg n "$name" --arg v "$value" '{name: $n, value: $v}')
    if [ -z "$value" ]; then m=DELETE; ok=$(write DELETE "repos/$REPO/actions/variables/$name" && echo y)
    elif [ -z "$have_v" ]; then m=POST; ok=$(write POST "repos/$REPO/actions/variables" "$body" && echo y)
    else m=PATCH; ok=$(write PATCH "repos/$REPO/actions/variables/$name" "$body" && echo y); fi
    if [ "$ok" = y ]; then mark "$k"; else err "$k" "$m refused: $(tr -d '\n' < "$TMP/err" | cut -c1-200)"; fi
  done
  # GitHub refuses the security updates without the alerts: turning on, the alerts first; turning the alerts off,
  # the security updates first.
  pairs="vulnerability_alerts:vulnerability-alerts automated_security_fixes:automated-security-fixes"
  [ "$(jq -r '.[] | select(.key == "vulnerability_alerts") | .want' <<<"$rows")" = false ] &&
    pairs="automated_security_fixes:automated-security-fixes vulnerability_alerts:vulnerability-alerts"
  for pair in $pairs; do
    k=${pair%%:*}; p=${pair#*:}
    [ -n "$(drifted "$k")" ] || continue
    m=DELETE; [ "$(jq -r --arg k "$k" '.[] | select(.key == $k) | .want' <<<"$rows")" = true ] && m=PUT
    if write "$m" "repos/$REPO/$p"; then mark "$k"; else err "$k" "$m refused: $(tr -d '\n' < "$TMP/err" | cut -c1-200)"; fi
  done
fi

# shellcheck disable=SC2016
doc=$(jq -n --arg r "$REPO" --argjson fork "$fork" --arg role "$role" --argjson rows "$rows" --argjson errors "$errors" '
  ($rows | map(select((.ok | not) and .have != null) | .key)) as $drift
  | ($rows | map(select(.applied) | .key)) as $applied
  | {repo: $r, fork: $fork, role: (if $role == "" then null else $role end),
     ok: ((($drift - $applied) | length) == 0 and ($errors | length) == 0),
     settings: $rows, drift: $drift, applied: $applied, errors: $errors}')
if [ "$JSON" = true ]; then echo "$doc"
else
  jq -r '.settings[] | "\(if .applied then "applied" elif .ok then "ok" elif .have == null then "unread" elif .readOnly then "drift (read-only)" else "drift" end)\t\(.key)\twant \(.want|tostring|if . == "" then "(unset)" else . end), have \(.have|tostring|if . == "" then "(unset)" else . end)\t(\(.source))"' <<<"$doc"
  jq -r '.errors[] | "error\t\(.key // "-")\t\(.message)"' <<<"$doc"
  jq -r 'if .ok then "\(.repo): repository settings OK" else "\(.repo): \((.drift - .applied) | length) setting(s) drifting, \(.errors | length) error(s)" end' <<<"$doc"
fi
[ "$(jq -r .ok <<<"$doc")" = true ]
