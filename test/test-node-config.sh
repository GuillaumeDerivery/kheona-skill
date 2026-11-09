#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline tests for .github/scripts/kskill-node-config.sh ci: the gate's `run` output.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/.github/scripts/kskill-node-config.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
check() { # check <name> <actual> <expected>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else failn=$((failn+1)); echo "FAIL $1: got '$2', want '$3'"; fi
}
repo() { # repo <.kheona.json>
  rm -rf "$T/r"; mkdir -p "$T/r"
  printf '%s' '{"name":"x","engines":{"node":"24"},"scripts":{"lint":"eslint . --max-warnings=0","test":"node --test","build":"tsc","typecheck":"tsc --noEmit","format:check":"prettier --check .","depcruise":"depcruise src","knip":"knip","coverage":"c8 node --test","coverage:check":"c8 check-coverage"}}' > "$T/r/package.json"
  printf '%s' "$1" > "$T/r/.kheona.json"; : > "$T/r/package-lock.json"
}
run_of() { # run_of <event> <called>: the `run` output
  : > "$T/out"
  (cd "$T/r" && EVENT_NAME=$1 CALLED=$2 GITHUB_OUTPUT="$T/out" GITHUB_STEP_SUMMARY=/dev/null bash "$SCRIPT" ci > /dev/null 2>&1)
  sed -n 's/^run=//p' "$T/out"
}

repo '{"role":"project","workflows":{"ci":{"runOnPush":false}}}'
check "runOnPush false: a push run still runs (the production deploy's gate is a push)" "$(run_of push false)" true
check "runOnPush false: a called push run runs"                                          "$(run_of push true)" true
check "runOnPush false: a pull request runs"                                             "$(run_of pull_request false)" true
repo '{"role":"project"}'
check "default: a push run runs"                                                         "$(run_of push false)" true

echo "node-config: $pass passed, $failn failed"
[ "$failn" = 0 ]
