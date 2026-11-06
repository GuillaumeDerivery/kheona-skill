#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Exchanges this job's GitHub OIDC identity for an App token, writes it to GITHUB_OUTPUT as `token`, masked.
# Env: KSKILL_TOKEN_BROKER_URL; KSKILL_TOKEN_REPOSITORY, KSKILL_TOKEN_SHARED, KSKILL_TOKEN_PERMISSIONS (see the action);
# ACTIONS_ID_TOKEN_REQUEST_URL and ACTIONS_ID_TOKEN_REQUEST_TOKEN, set by GitHub under `id-token: write`.
set -euo pipefail
: "${KSKILL_TOKEN_BROKER_URL:?Variable KSKILL_TOKEN_BROKER_URL is not set}"
if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "::error::This job has no OIDC identity: it needs the permission id-token: write, in the caller too."
  exit 1
fi
audience=${KSKILL_TOKEN_AUDIENCE:-kskill-token-broker}
id_token=$(curl -fsS --max-time 20 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$audience" | jq -r .value)
echo "::add-mask::$id_token"
body=$(jq -n --arg r "${KSKILL_TOKEN_REPOSITORY:-}" --arg s "${KSKILL_TOKEN_SHARED:-false}" --arg p "${KSKILL_TOKEN_PERMISSIONS:-}" \
  '{shared: ($s == "true")} + (if $r != "" then {repository: $r} else {} end) + (if $p != "" then {permissions: ($p | fromjson)} else {} end)')
response=$(curl -sS --max-time 20 -w '\n%{http_code}' -H "Authorization: Bearer $id_token" -H 'Content-Type: application/json' \
  -d "$body" "${KSKILL_TOKEN_BROKER_URL%/}/token")
status=${response##*$'\n'}
json=${response%$'\n'*}
if [ "$status" != 200 ]; then
  echo "::error::The token broker refused: HTTP $status $(jq -r '.error // empty' <<<"$json" 2>/dev/null)"
  exit 1
fi
token=$(jq -r .token <<<"$json")
echo "::add-mask::$token"
echo "token=$token" >> "$GITHUB_OUTPUT"
