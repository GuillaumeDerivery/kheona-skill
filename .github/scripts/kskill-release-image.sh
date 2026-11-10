#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Whether production may run the image staging tested instead of building the release commit: true only when the
# release commit changes nothing but versions. Allowed: CHANGELOG.md and .release-please-manifest.json whole; in any
# other file, only lines setting a version ("version": "1.2.0" in package.json and package-lock.json, version: in
# pubspec.yaml, version = in pyproject.toml). Anything else, or an API error, builds the release in full.
# Env: GH_TOKEN, GH_REPO, TESTED (the commit before the release), GITHUB_SHA (the release). Writes promote=true|false.
set -uo pipefail
out=${GITHUB_OUTPUT:-/dev/stdout}
no() { echo "::notice::Production builds $GITHUB_SHA in full: $1"; echo "promote=false" >> "$out"; exit 0; }
[[ "${TESTED:-}" =~ ^[0-9a-f]{40}$ ]] || no "no tested commit before the release."
files=$(gh api "repos/$GH_REPO/compare/$TESTED...$GITHUB_SHA" --jq '[.files[] | {filename, patch: (.patch // null)}]' 2>/dev/null) ||
  no "the comparison with ${TESTED:0:7} failed."
[ "$(jq -r 'length' <<<"$files")" -gt 0 ] 2>/dev/null || no "the comparison with ${TESTED:0:7} lists no file."
other=$(jq -r '.[] | select(.filename != "CHANGELOG.md" and .filename != ".release-please-manifest.json")
  | select(.patch == null or ([.patch | split("\n")[] | select(test("^[-+]")) | select(test("^[-+]\\s*\"?version\"?\\s*[:=]") | not)] | length > 0))
  | .filename' <<<"$files")
[ -z "$other" ] || no "the release commit changes more than versions ($(tr '\n' ' ' <<<"$other"))."
echo "promote=true" >> "$out"
echo "The release commit changes only versions: production runs the image staging tested (${TESTED:0:7})."
