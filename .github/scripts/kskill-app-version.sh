#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The version a service reports, given at deploy time as APP_VERSION (never built into the image, so staging and
# production run the same image):
#   production (VERSION=vX.Y.Z)  X.Y.Z
#   staging                      <last release>+<commits since>.<short commit>, e.g. 1.4.0+3.a1b2c3d (SemVer build
#                                metadata: after 1.4.0, not a release); 0.0.0+<short commit> before any release.
# The commit stays the image's own GIT_SHA. Env: GH_TOKEN, GH_REPO, GITHUB_SHA, VERSION. Writes app-version=...
set -uo pipefail
out=${GITHUB_OUTPUT:-/dev/stdout}
short=${GITHUB_SHA:0:7}
if [[ "${VERSION:-}" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then echo "app-version=${BASH_REMATCH[1]}" >> "$out"; exit 0; fi
last=$(gh api "repos/$GH_REPO/releases/latest" --jq .tag_name 2>/dev/null || true)
if [[ "$last" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  base=${BASH_REMATCH[1]}
  ahead=$(gh api "repos/$GH_REPO/compare/$last...$GITHUB_SHA" --jq .ahead_by 2>/dev/null || true)
  [[ "$ahead" =~ ^[0-9]+$ ]] && echo "app-version=$base+$ahead.$short" >> "$out" || echo "app-version=$base+$short" >> "$out"
else
  echo "app-version=0.0.0+$short" >> "$out"
fi
