# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# / ci-cd.md "The publish lane": derives the store build number from the repository, never from a store
# lookup (both stores' lookups lag what their upload endpoint enforces, and reading each store separately
# lets iOS and Android drift apart). Both store lanes run it on the same commit, so both get one number.
#   BUILD_NUMBER = git rev-list --count HEAD + KSKILL_BUILD_NUMBER_OFFSET   (offset: .kheona.json, default 0)
# BUILD_NUMBER_OVERRIDE (the repository variable of the same name), when set, wins as is, offset not added:
# the escape hatch for re-shipping an unchanged commit. Clear it again after the run; an empty commit on
# `prod` does the same and leaves a trace in git.
# Fails on a shallow clone (the count would be 1, which every store rejects) and on a number past Android's
# versionCode ceiling. Exports BUILD_NUMBER to $GITHUB_ENV when set, and prints it.
# Usage: bash .github/scripts/kskill-build-number.sh
set -euo pipefail

override="${BUILD_NUMBER_OVERRIDE:-}"
offset="${KSKILL_BUILD_NUMBER_OFFSET:-0}"
max=2100000000

export_number() {
  if [ "$1" -gt "$max" ]; then
    echo "::error::Build number $1 is past Android's versionCode ceiling ($max)."
    exit 1
  fi
  if [ -n "${GITHUB_ENV:-}" ]; then echo "BUILD_NUMBER=$1" >> "$GITHUB_ENV"; fi
  echo "Build number $1 ($2)."
}

if [ -n "$override" ]; then
  case "$override" in
    *[!0-9]*|0*) echo "::error::BUILD_NUMBER_OVERRIDE must be a positive integer, got '$override'."; exit 1 ;;
  esac
  export_number "$override" "overridden by the BUILD_NUMBER_OVERRIDE repository variable: clear it after this run"
  exit 0
fi

case "$offset" in
  ''|*[!0-9]*) echo "::error::workflows.cd.buildNumber.offset must be a non-negative integer, got '$offset'."; exit 1 ;;
esac

if [ "$(git rev-parse --is-shallow-repository)" != "false" ]; then
  echo "::error::Shallow clone: the commit count would be wrong. The checkout needs fetch-depth: 0."
  exit 1
fi

count="$(git rev-list --count HEAD)"
if [ "$count" -lt 2 ]; then
  echo "::error::Commit count is $count: check the checkout's fetch depth."
  exit 1
fi

export_number "$((count + offset))" "commit count $count + offset $offset at $(git rev-parse --short HEAD)"
