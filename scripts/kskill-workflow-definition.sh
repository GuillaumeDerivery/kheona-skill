#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The definition every catalogued workflow carries (the map's one-line summary on its Workflows card): at the top of
# its leading comment block (after the "Generated" line of a template, or after `name:`), the three
# header fields, one line each (a line indented by two more spaces continues one):
#   # Trigger: what starts it, and who or what does (a PR, a push, the doctor's dispatch, a person by hand...)
#   # Purpose: what it does
#   # Effect:  what it may change (merges, deploys, PRs, issues, commits, releases), or "nothing: reports only"
# The map reads them into the catalog (`definition`); no list is kept anywhere else.
#   scripts/kskill-workflow-definition.sh <workflow.yml>...   prints "<file>: no <Field>: line" per missing field; exit 1 if any
set -uo pipefail
status=0
for f in "$@"; do
  # The leading comment block: comment lines from the top, a `name:` line and blank lines before it allowed.
  block=$(awk '
    /^#/ { sub(/^# ?/, ""); print; seen = 1; next }
    seen { exit }
    /^name:/ || /^[[:space:]]*$/ { next }
    { exit }' "$f" | sed '1{/^Generated/d;}')
  # The fields are the block's first lines: stop at the first line that is neither a field nor its continuation.
  head=$(awk '/^(Trigger|Purpose|Effect):/ { print; next } /^  [^ ]/ && NR > 1 { next } { exit }' <<< "$block")
  for field in Trigger Purpose Effect; do
    if ! grep -qE "^$field: *[^ ]" <<< "$head"; then echo "$f: no \"# $field:\" line at the top of its leading comment"; status=1; fi
  done
done
exit "$status"
