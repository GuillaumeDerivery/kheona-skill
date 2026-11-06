#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline-once tests for scripts/kskill-secret-scan.sh, against throwaway git repositories and the real pinned gitleaks
# (downloaded once into a cache, checksum-verified). The fake credentials are made here from fixed seeds, never committed.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export KSKILL_CACHE="${KSKILL_CACHE:-$T/cache}"
# Findings fail (SECRETS_FAILS long past); the grace test below sets a future date.
sed 's/^SECRETS_FAILS=.*/SECRETS_FAILS=2000-01-01/' "$HERE/scripts/kskill-secret-scan.sh" > "$T/scan.sh"
SCAN="$T/scan.sh"
pass=0; failn=0
jexpect() { # jexpect <name> <exit code> <jq expression that must be true> <repo>
  local name=$1 want=$2 q=$3 repo=$4 out code
  out=$(bash "$SCAN" --json "$repo" 2>/dev/null); code=$?
  if [ "$code" = "$want" ] && [ "$(jq -r "$q" <<<"$out" 2>/dev/null)" = true ]; then pass=$((pass+1)); echo "ok   $name"
  else failn=$((failn+1)); echo "FAIL $name (exit $code, want $want; $q)"; printf '     %s\n' "$out"; fi
}
expect() { # expect <name> <exit code> <grep -E pattern> <repo> [absent]
  local name=$1 want=$2 pat=$3 repo=$4 out code
  out=$(GITHUB_ACTIONS=${GA:-} bash "$SCAN" "$repo" 2>&1); code=$?
  if [ "$code" = "$want" ] && { { [ "${5:-}" = absent ] && ! grep -qE "$pat" <<<"$out"; } || { [ "${5:-}" != absent ] && grep -qE "$pat" <<<"$out"; }; }; then pass=$((pass+1)); echo "ok   $name"
  else failn=$((failn+1)); echo "FAIL $name (exit $code, want $want; pattern $pat ${5:-})"; printf '     %s\n' "${out//$'\n'/$'\n'     }"; fi
}
g() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}" >/dev/null; }
# A fake key: 32 letters and digits of the SHA-256 of a seed. Fixed, not random: about 1 random draw in 200 is not flagged
# by gitleaks' generic-api-key rule (its entropy and stopword filters), which made this test fail now and then (#177's CI).
# Both seeds give keys the pinned gitleaks flags; a test below fails if a new seed or gitleaks version stops doing so.
key() { node -e 'process.stdout.write(require("crypto").createHash("sha256").update(process.argv[1]).digest("base64").replace(/[^A-Za-z0-9]/g, "").slice(0, 32))' "$1"; }
K1=$(key kheona-fixture-1); K2=$(key kheona-fixture-2)

r="$T/clean"; mkdir -p "$r/config"; g "$r" init; printf '{"db":{"connectionString":""}}\n' > "$r/config/a.json"; g "$r" add -A; g "$r" commit -qm a
jexpect "nothing committed: ok, no finding, the pinned version" 0 '.ok and .findings == [] and .skipped == null and (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$r"
expect "... says so"                                0 'Secret scan \(gitleaks [0-9.]+\): nothing found' "$r"

r="$T/leak"; mkdir -p "$r/config/core" "$r/src"; g "$r" init
printf '{\n  "vendor": {\n    "apiKey": "%s"\n  }\n}\n' "$K1" > "$r/config/core/base.json"
printf 'export const x = 1;\nconst api_key = "%s";\n' "$K2" > "$r/src/client.ts"
g "$r" add -A; g "$r" commit -qm a
jexpect "a committed key: each file and line, its rule and fingerprint" 1 '(.ok | not) and ([.findings[] | "\(.path):\(.line):\(.rule)"] == ["config/core/base.json:3:generic-api-key", "src/client.ts:2:generic-api-key"]) and (.findings[0].fingerprint == "config/core/base.json:generic-api-key:3")' "$r"
out=$(bash "$SCAN" --json "$r" 2>&1; GITHUB_ACTIONS=true bash "$SCAN" "$r" 2>&1; bash "$SCAN" "$r" 2>&1)
if grep -qF -e "$K1" -e "$K2" <<<"$out"; then failn=$((failn+1)); echo "FAIL the value is printed"; else pass=$((pass+1)); echo "ok   never the value, in any output"; fi
GA=true expect "an error annotation per file, at its first line" 1 '^::error file=config/core/base\.json,line=3::gitleaks: 1 credential\(s\) committed here \(rule generic-api-key; line 3\)' "$r"
printf '{"vendor":{"apiKey":""}}\n' > "$r/config/core/base.json"
jexpect "what is committed, not the working tree" 1 '[.findings[].path] == ["config/core/base.json", "src/client.ts"]' "$r"
g "$r" checkout -q -- .
printf '# a test fixture, not a key\nsrc/client.ts:generic-api-key:2\n' > "$r/.gitleaksignore"
printf '[extend]\nuseDefault = true\n[allowlist]\ndescription = "vendor sandbox ids"\npaths = ['"'"'''^config/core/'"'"''']\n' > "$r/.gitleaks.toml"
g "$r" add -A; g "$r" commit -qm b
jexpect "the repository's .gitleaks.toml allowlist and .gitleaksignore fingerprint" 0 '.ok and .findings == []' "$r"
printf '[extend\n' > "$r/.gitleaks.toml"; g "$r" add -A; g "$r" commit -qm c
jexpect "an invalid .gitleaks.toml: did not run (exit 2)" 2 '(.ok | not) and .findings == []' "$r"
g "$r" rm -q .gitleaks.toml; g "$r" commit -qm d

# git-crypt: a file stored encrypted is read as git stores it, even in an unlocked clone (the filter is off for the scan).
r="$T/crypt"; mkdir -p "$r/k/secrets"; g "$r" init
printf 'k/secrets/** filter=git-crypt diff=git-crypt\n' > "$r/.gitattributes"
printf '\0GITCRYPT\0%s' "$(key kheona-crypt-1)$(key kheona-crypt-2)" > "$r/k/secrets/s.yaml"
g "$r" add -A; g "$r" commit -qm a
printf 'stringData:\n  api_key: "%s"\n' "$K1" > "$T/plain.yaml"
git -C "$r" config filter.git-crypt.smudge "cat $T/plain.yaml #"; git -C "$r" config filter.git-crypt.required true
jexpect "a git-crypt file: never decrypted for the scan" 0 '.ok and .findings == []' "$r"

r="$T/skip"; mkdir -p "$r"; g "$r" init; printf 'api_key = "%s"\n' "$K1" > "$r/app.ini"
echo '{"workflows":{"ci":{"skip":{"secretScan":"vendored fixtures, reviewed"}}}}' > "$r/.kheona.json"; g "$r" add -A; g "$r" commit -qm a
jexpect "workflows.ci.skip.secretScan with a reason: off, and says why" 0 '.ok and .skipped == "vendored fixtures, reviewed" and .findings == []' "$r"
echo '{"workflows":{"ci":{"skip":{"secretScan":" "}}}}' > "$r/.kheona.json"; g "$r" add -A; g "$r" commit -qm b
expect "... a blank reason is an error, and the scan runs" 1 'workflows\.ci\.skip\.secretScan is the reason.*' "$r"

sed 's/^SECRETS_FAILS=.*/SECRETS_FAILS=2999-01-01/' "$HERE/scripts/kskill-secret-scan.sh" > "$T/scan-young.sh"
SCAN_ORIG=$SCAN; SCAN="$T/scan-young.sh"
jexpect "before SECRETS_FAILS: ok, the findings listed" 0 '.ok and ([.findings[].path] == ["app.ini"])' "$r"
GA=true expect "... as warnings naming the day" 0 '^::warning file=app\.ini,line=1::.*\(an error from 2999-01-01\)' "$r"
SCAN=$SCAN_ORIG

r="$T/nogit"; mkdir -p "$r"; printf 'api_key = "%s"\n' "$K2" > "$r/app.ini"
jexpect "outside git: the files themselves" 1 '[.findings[].path] == ["app.ini"]' "$r"
KSKILL_GITLEAKS=/nonexistent/gitleaks jexpect "gitleaks unavailable: exit 2, not a pass" 2 '(.ok | not)' "$r"

echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
