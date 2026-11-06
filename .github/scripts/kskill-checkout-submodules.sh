# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# Clones the repository's submodules (a private lib behind an SSH or HTTPS GitHub URL) over HTTPS with a read-only
# token of the automation App (the workflow mints it for the library repository).
# The token is given to git through GIT_CONFIG_* variables of this process only: it is never written to
# .gitmodules, .git/config or any file, so no later `git add` can publish it, and the submodules keep their
# committed URLs. Never prints the token.
#
# Usage, from the repository root, with SUBMODULE_TOKEN in the environment: bash .github/scripts/kskill-checkout-submodules.sh
set -euo pipefail

[ -n "${SUBMODULE_TOKEN:-}" ] || { echo "::error::No SUBMODULE_TOKEN: the variable KSKILL_TOKEN_BROKER_URL are not set, or not available to this run (fork PRs never get secrets). They clone the private submodules." >&2; exit 1; }
[ -f .gitmodules ] || { echo "No .gitmodules: nothing to clone."; exit 0; }

# url.<base>.insteadOf, twice: SSH and HTTPS forms of github.com both resolve to the authenticated base.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0="url.https://x-access-token:${SUBMODULE_TOKEN}@github.com/.insteadOf"
export GIT_CONFIG_VALUE_0="git@github.com:"
export GIT_CONFIG_KEY_1="url.https://x-access-token:${SUBMODULE_TOKEN}@github.com/.insteadOf"
export GIT_CONFIG_VALUE_1="https://github.com/"

git submodule sync --recursive
git submodule update --init --recursive
git submodule status --recursive
