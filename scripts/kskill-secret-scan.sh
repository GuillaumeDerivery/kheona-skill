#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# no credential in a repository's files. gitleaks (pinned below, checksum-verified) scans what is committed (the
# HEAD tree, as git stores it: a git-crypt file stays encrypted and is not read), with the repository's own
# .gitleaks.toml (`[extend] useDefault = true`, then an `[allowlist]` of paths or regexes for false positives) and
# .gitleaksignore (one fingerprint `<path>:<rule>:<line>` per line, a `#` comment saying why) when it has them.
# A step of every `Kheona Skill · CI` (actions/kskill-repo-check); the map collector reads --json .
#
# Usage: kskill-secret-scan.sh [--json] <repo-root>
#   --json: one document instead of annotations, same exit code:
#     { "ok": bool, "skipped": "<reason>" | null, "version": "<gitleaks version>",
#       "findings": [{ "path", "line", "rule", "fingerprint" }] }   (never the secret, never the matching line)
# Off with .kheona.json `workflows.ci.skip.secretScan`, its value the reason (a non-empty string).
# Findings only warn before SECRETS_FAILS (UTC), then fail. Exit 2: gitleaks could not run.
# Env: KSKILL_GITLEAKS, a gitleaks binary to use instead of downloading the pinned one (tests); KSKILL_CACHE, where the
#      download is kept (default ${XDG_CACHE_HOME:-$HOME/.cache}/kheona).
# shellcheck disable=SC2034  # why: the GITLEAKS_SHA256_* pins are read by name in gitleaks_bin (${!sum})
set -uo pipefail
GITLEAKS_VERSION=8.30.1
# From the release's gitleaks_<version>_checksums.txt (read by name in gitleaks_bin).
GITLEAKS_SHA256_linux_x64=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
GITLEAKS_SHA256_linux_arm64=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080
GITLEAKS_SHA256_darwin_arm64=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5
GITLEAKS_SHA256_darwin_x64=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709
# The scan started 2026-10-28: its findings only warn before this day (UTC), then fail.
SECRETS_FAILS=2026-11-11

JSON=false
if [ "${1:-}" = --json ]; then JSON=true; shift; fi
REPO=${1:?usage: kskill-secret-scan.sh [--json] <repo-root>}
REPO=$(cd "$REPO" && pwd) || exit 64
say() { [ "$JSON" = true ] || echo "$@"; }
annotate() { # annotate <level> <file> <line> <message>: a GitHub annotation in Actions, plain text elsewhere
  [ "$JSON" = true ] && return 0
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::$1 file=$2,line=$3::$4"; else echo "$1: $2:$3: $4"; fi
}
doc() { # doc <ok> <skipped or ""> <findings file, or "" for none> (a file: thousands of findings exceed an argument)
  [ "$JSON" = true ] && jq -n --argjson ok "$1" --arg s "$2" --arg v "$GITLEAKS_VERSION" --slurpfile f "${3:-/dev/null}" \
    '{ok: $ok, skipped: (if $s == "" then null else $s end), version: $v, findings: ($f[0] // [])}'
  return 0
}

CFG="$REPO/.kheona.json"
if [ -f "$CFG" ] && [ "$(jq -r '.workflows.ci.skip // {} | type == "object" and has("secretScan")' "$CFG" 2>/dev/null)" = true ]; then
  reason=$(jq -r '.workflows.ci.skip.secretScan | if type == "string" then sub("^\\s+|\\s+$"; "") else "" end' "$CFG")
  if [ -z "$reason" ]; then
    annotate error .kheona.json 1 "workflows.ci.skip.secretScan is the reason the secret scan is off: a non-empty string"
  else
    say "Secret scan off: $reason (.kheona.json workflows.ci.skip.secretScan)"; doc true "$reason" ""; exit 0
  fi
fi

# The pinned gitleaks, downloaded once per version into the cache and checked against its checksum.
gitleaks_bin() {
  if [ -n "${KSKILL_GITLEAKS:-}" ]; then (cd "$(dirname "$KSKILL_GITLEAKS")" && echo "$PWD/$(basename "$KSKILL_GITLEAKS")"); return; fi
  local os arch sum dir tgz
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) return 1 ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=x64 ;; arm64|aarch64) arch=arm64 ;; *) return 1 ;; esac
  sum=GITLEAKS_SHA256_${os}_${arch}; sum=${!sum:-}
  [ -n "$sum" ] || return 1
  dir="${KSKILL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/kheona}/gitleaks-$GITLEAKS_VERSION-${os}_$arch"
  mkdir -p "$dir" && dir=$(cd "$dir" && pwd) || return 1
  if [ ! -x "$dir/gitleaks" ]; then
    tgz="$dir/gitleaks.tar.gz"
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$tgz" "https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION/gitleaks_${GITLEAKS_VERSION}_${os}_$arch.tar.gz" || return 1
    if [ "$( { sha256sum "$tgz" 2>/dev/null || shasum -a 256 "$tgz"; } | awk '{ print $1 }')" != "$sum" ]; then rm -f "$tgz"; return 1; fi
    tar -xzf "$tgz" -C "$dir" gitleaks && rm -f "$tgz" || return 1
  fi
  echo "$dir/gitleaks"
}
if ! GL=$(gitleaks_bin) || [ ! -x "$GL" ]; then
  annotate error . 1 "gitleaks $GITLEAKS_VERSION could not be installed (download or checksum): the secret scan did not run"
  doc false "" ""; exit 2
fi

# What is committed: the HEAD tree as git stores it. The git-crypt filter is turned off for the export, so an unlocked
# clone reads like CI's (encrypted files stay binary); outside git, the files themselves.
TREE=$(mktemp -d); REPORT=$(mktemp); FOUND=$(mktemp); trap 'rm -rf "$TREE" "$REPORT" "$FOUND"' EXIT
if git -C "$REPO" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  git -C "$REPO" -c filter.git-crypt.smudge=cat -c filter.git-crypt.required=false archive --format=tar HEAD | tar -x -C "$TREE" || exit 2
else
  (cd "$REPO" && tar -c --exclude=.git . | tar -x -C "$TREE") || exit 2
fi
# gitleaks finds .gitleaks.toml in the scanned directory and .gitleaksignore in the working directory.
if ! (cd "$TREE" && "$GL" dir . --no-banner --redact -f json -r "$REPORT" --exit-code 0 -l error >/dev/null 2>&1); then
  annotate error . 1 "gitleaks failed (an invalid .gitleaks.toml?): the secret scan did not run"
  doc false "" ""; exit 2
fi
jq -c '[.[] | {path: (.File | sub("^\\./"; "")), line: .StartLine, rule: .RuleID, fingerprint: .Fingerprint}] | sort_by(.path, .line)' "$REPORT" > "$FOUND"
n=$(jq length "$FOUND")
if [ "$n" = 0 ]; then say "Secret scan (gitleaks $GITLEAKS_VERSION): nothing found"; doc true "" "$FOUND"; exit 0; fi

fails=$(jq -n --arg d "$SECRETS_FAILS" '$d + "T00:00:00Z" | fromdateiso8601')
if [ "$(date +%s)" -lt "$fails" ]; then level=warning; tail=" (an error from $SECRETS_FAILS)"; else level=error; tail=""; fi
# One annotation per file (a generated data file can match thousands of times): its count, rules and first lines.
while IFS=$'\t' read -r p l c r ls; do
  annotate "$level" "$p" "$l" "gitleaks: $c credential(s) committed here (rule $r; line $ls). A real one moves to the environment (the deployment's Secret, the local .env) and is rotated, since the history keeps it; a false positive goes in .gitleaks.toml [allowlist] (a path or regex) or .gitleaksignore (<path>:<rule>:<line>) with the reason$tail"
done < <(jq -r 'group_by(.path)[] | [.[0].path, .[0].line, length, ([.[].rule] | unique | join(", ")),
  (([.[].line] | .[:10] | map(tostring) | join(", ")) + (if length > 10 then ", ..." else "" end))] | @tsv' "$FOUND")
say "Secret scan (gitleaks $GITLEAKS_VERSION): $n finding(s) in $(jq '[.[].path] | unique | length' "$FOUND") file(s), see the annotations$tail"
if [ "$level" = error ]; then doc false "" "$FOUND"; exit 1; fi
doc true "" "$FOUND"; exit 0
