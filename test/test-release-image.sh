#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline tests for .github/scripts/kskill-release-image.sh (production reuses staging's image only when the release
# commit changes versions alone) and kskill-app-version.sh (APP_VERSION), with a fake gh.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failn=$((failn+1)); echo "FAIL $1 (got: $2)"; fi; }
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
jqx=.; path=""; args=("$@")
for ((i = 1; i < ${#args[@]}; i++)); do case "${args[i]}" in --jq) jqx=${args[i+1]}; i=$((i+1)) ;; -*) ;; *) [ -n "$path" ] || path=${args[i]} ;; esac; done
case "$path" in
  */compare/*) f=compare.json ;;
  */releases/latest) f=latest.json ;;
  *) exit 1 ;;
esac
[ -f "$FAKE/$f" ] || { echo "HTTP 404" >&2; exit 1; }
jq -r "$jqx" "$FAKE/$f"
GH
chmod +x "$T/bin/gh"
FAKE=$T/fake; mkdir -p "$FAKE"
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
img() { (PATH="$T/bin:$PATH" FAKE="$FAKE" GH_REPO=o/r TESTED=${TESTED-$A} GITHUB_SHA=$B GITHUB_OUTPUT=/dev/stdout bash "$HERE/.github/scripts/kskill-release-image.sh" 2>&1); }
files() { jq -n --argjson f "$1" '{files: $f}' > "$FAKE/compare.json"; }

files '[{"filename":"CHANGELOG.md","patch":"@@ -1 +1,3 @@\n+## 1.2.0\n+* x"},{"filename":".release-please-manifest.json","patch":"-  \".\": \"1.1.0\"\n+  \".\": \"1.2.0\""},{"filename":"package.json","patch":"@@ -2 +2 @@\n-  \"version\": \"1.1.0\",\n+  \"version\": \"1.2.0\","},{"filename":"package-lock.json","patch":"@@ -3 +3 @@\n-  \"version\": \"1.1.0\",\n+  \"version\": \"1.2.0\",\n@@ -9 +9 @@\n-      \"version\": \"1.1.0\",\n+      \"version\": \"1.2.0\","}]'
check "versions only: promote" "$(img)" 'promote=true'
files '[{"filename":"pubspec.yaml","patch":"-version: 1.1.0+3\n+version: 1.2.0+4"},{"filename":"pyproject.toml","patch":"-version = \"1.1.0\"\n+version = \"1.2.0\""}]'
check "pubspec and pyproject versions: promote" "$(img)" 'promote=true'
files '[{"filename":"package.json","patch":"-  \"version\": \"1.1.0\",\n+  \"version\": \"1.2.0\",\n+  \"main\": \"x.js\","}]'
check "another line changed: build" "$(img)" 'promote=false'
check "... and says which file" "$(img)" 'more than versions \(package\.json'
files '[{"filename":"src/a.ts","patch":"+const version = 2"}]'
check "a source file: build" "$(img)" 'promote=false'
files '[{"filename":"logo.png"}]'
check "a binary file (no patch): build" "$(img)" 'promote=false'
files '[]'
check "nothing compared: build" "$(img)" 'promote=false'
rm "$FAKE/compare.json"
check "an API error: build" "$(img)" 'promote=false'
check "no tested commit: build" "$(TESTED='' img)" 'promote=false'

ver() { (PATH="$T/bin:$PATH" FAKE="$FAKE" GH_REPO=o/r GITHUB_SHA=$B VERSION=${1:-} GITHUB_OUTPUT=/dev/stdout bash "$HERE/.github/scripts/kskill-app-version.sh" 2>&1); }
check "production: the tag's version" "$(ver v1.2.0)" '^app-version=1\.2\.0$'
echo '{"tag_name":"v1.4.0"}' > "$FAKE/latest.json"; echo '{"ahead_by":3}' > "$FAKE/compare.json"
check "staging: after the last release" "$(ver)" '^app-version=1\.4\.0\+3\.bbbbbbb$'
rm "$FAKE/compare.json"
check "staging, no comparison: release and commit" "$(ver)" '^app-version=1\.4\.0\+bbbbbbb$'
rm "$FAKE/latest.json"
check "staging before any release" "$(ver)" '^app-version=0\.0\.0\+bbbbbbb$'

echo "release-image: $pass passed, $failn failed"; [ "$failn" = 0 ]
