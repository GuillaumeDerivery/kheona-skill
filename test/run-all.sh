#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Every test of this repository. Exit 1 when any fails.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); cd "$HERE" || exit 64
rc=0
for t in test/test-*.sh; do
  echo "== $t"
  bash "$t" </dev/null > "${TMPDIR:-/tmp}/kskill-test.log" 2>&1 || { rc=1; grep -E '^FAIL|rror' "${TMPDIR:-/tmp}/kskill-test.log" | head -20; }
  tail -n 1 "${TMPDIR:-/tmp}/kskill-test.log"
done
echo "== token broker"; node --test terraform/token-broker/worker/test/*.test.mjs > "${TMPDIR:-/tmp}/kskill-node.log" 2>&1 || rc=1; grep -E '(pass|fail) [0-9]+$' "${TMPDIR:-/tmp}/kskill-node.log"
echo "== shellcheck"; find .github/scripts scripts test -name '*.sh' -print0 | xargs -0 shellcheck -S warning || rc=1
if command -v actionlint >/dev/null; then echo "== actionlint"; actionlint -ignore 'specifying action "\$/' .github/workflows/*.yml || rc=1; fi
exit "$rc"
