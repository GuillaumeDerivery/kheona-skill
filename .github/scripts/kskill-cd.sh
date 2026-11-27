#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The effective .kheona.json: the file, with the Actions variable KSKILL_CD laid over its `workflows.cd`.
#
# Usage: KSKILL_CD="$(vars.KSKILL_CD)" kskill-cd.sh [<.kheona.json>]   (default ./.kheona.json; prints JSON)
#
# Why: a fork carries nothing of its own in git. Every repository of a fork network shares its git data, so whatever
# one fork commits (an account, a role, a cluster, a namespace) is readable from every other fork by its SHA. A fork's
# deploy settings therefore live in its repository variable KSKILL_CD, never in a commit: its .kheona.json is the
# parent's, byte for byte.
# KSKILL_CD is a JSON object with the keys of `workflows.cd` (staging, prod, platform, environmentVariable, ...). Each
# key it sets replaces the file's (an environment object is replaced whole, not merged). Unset or empty: the file as
# it is. Not a JSON object: exit 1, naming the variable (its value is never printed).
set -euo pipefail

f=${1:-.kheona.json}
[ -f "$f" ] || { echo "kskill-cd.sh: $f is missing" >&2; exit 1; }
jq -e 'type == "object"' "$f" > /dev/null 2>&1 || { echo "kskill-cd.sh: $f is not a JSON object" >&2; exit 1; }

over=${KSKILL_CD:-}
if [ -z "${over//[[:space:]]/}" ]; then jq . "$f"; exit 0; fi
jq -e 'type == "object"' <<<"$over" > /dev/null 2>&1 ||
  { echo "kskill-cd.sh: the Actions variable KSKILL_CD is not a JSON object (it holds this fork's workflows.cd keys)" >&2; exit 1; }
jq --argjson o "$over" '.workflows = ((.workflows // {}) | .cd = ((.cd // {}) + $o))' "$f"
