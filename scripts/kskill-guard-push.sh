#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The guard before a push: install as .git/hooks/pre-push. Reads the list from KSKILL_GUARD_LIST.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
self=$(git -C "$root" remote get-url origin 2>/dev/null | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')
range=$(git -C "$root" rev-parse --verify -q '@{u}' >/dev/null && echo '@{u}..HEAD' || echo HEAD)
exec node "$root/.github/scripts/kskill-guard.mjs" --repo "$root" --self "$self" --commits "$range"
