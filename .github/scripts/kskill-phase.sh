# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# The repository's phase, from .kheona.json `phase`: "bootstrap" (a new repository: CI runs format, lint,
# typecheck and build, runs the tests that exist, reports coverage without a floor, no mutation testing) or
# "established" (every gate). Absent means established: a repository never loosens by omission; the skill writes
# "bootstrap" when it scaffolds one.
# The switch is enforced at the first production release: with --ship (the run ships to production: a push to
# `prod`, the release PR's `ship`, a library release), a repository still in bootstrap fails here, naming the fix.
#
# Usage, from the repository root: bash .github/scripts/kskill-phase.sh [--ship]
# Writes phase=<bootstrap|established> to $GITHUB_OUTPUT (stdout outside Actions). Never reads a secret.
set -euo pipefail

phase=established
if [ -f .kheona.json ]; then
  phase=$(jq -r '.phase // "established"' .kheona.json 2>/dev/null) || { echo "::error file=.kheona.json::not valid JSON" >&2; exit 1; }
fi
case "$phase" in
  bootstrap|established) ;;
  *) echo "::error file=.kheona.json::phase must be \"bootstrap\" or \"established\", found \"$phase\"." >&2; exit 1 ;;
esac

if [ "${1:-}" = --ship ] && [ "$phase" = bootstrap ]; then
  echo "::error file=.kheona.json::This is the first production release and the repository is still in its bootstrap phase. Set \"phase\": \"established\" in .kheona.json, with the coverage floor at today's measured figure, then ship again." >&2
  exit 1
fi
[ "$phase" = established ] || echo "::notice::bootstrap phase (.kheona.json): tests run where they exist, the coverage floor is reported, not enforced. It must be \"established\" before the first production release."
echo "phase=$phase" >> "${GITHUB_OUTPUT:-/dev/stdout}"
