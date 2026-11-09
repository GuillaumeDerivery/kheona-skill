#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Tests for the Claude Code skill at this repository's root: SKILL.md's frontmatter, every relative link of the skill's
# markdown, and enforce.sh's tiers against throwaway git repositories (offline: no stack tool is needed).
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
ENFORCE="$HERE/enforce.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { failn=$((failn+1)); echo "FAIL $1"; [ -z "${2:-}" ] || printf '     %s\n' "${2//$'\n'/$'\n'     }"; }
check() { # check <name> <output> <grep -E pattern> [absent]
  if { [ "${4:-}" = absent ] && ! grep -qE -- "$3" <<<"$2"; } || { [ "${4:-}" != absent ] && grep -qE -- "$3" <<<"$2"; }; then ok "$1"
  else bad "$1 (pattern $3 ${4:-})" "$2"; fi
}
newrepo() { rm -rf "$T/r"; mkdir -p "$T/r"; git -C "$T/r" init -q; }
in_repo() { (cd "$T/r" && bash "$ENFORCE" "$@" 2>&1); }

# --- SKILL.md and its links ---------------------------------------------------------------------------------------
bash -n "$ENFORCE" && ok "enforce.sh parses (bash -n)" || bad "enforce.sh parses (bash -n)"
fm=$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}' "$HERE/SKILL.md")
check "SKILL.md frontmatter: name kheona" "$fm" '^name: kheona$'
check "SKILL.md frontmatter: a description" "$fm" '^description: .{40,}'
broken=""
for md in "$HERE/SKILL.md" "$HERE"/stacks/*.md "$HERE"/docs/*.md "$HERE/README.md"; do
  dir=$(dirname "$md")
  while IFS= read -r link; do
    target=${link%%#*}
    [ -n "$target" ] || continue
    [ -e "$dir/$target" ] || broken="$broken${md#"$HERE"/} -> $link"$'\n'
  done < <(grep -oE '\]\([^)]+\)' "$md" | sed -E 's/^\]\((.*)\)$/\1/' | grep -vE '^(https?:|mailto:|#|<)')
done
[ -z "$broken" ] && ok "every relative markdown link resolves" || bad "every relative markdown link resolves" "$broken"
for f in "$HERE"/stacks/*.md; do
  check "stack file names a K-section: ${f##*/}" "$(cat "$f")" '^## K1'
done

# --- enforce.sh ---------------------------------------------------------------------------------------------------
newrepo
out=$(in_repo rules); code=$?
[ "$code" = 0 ] && [ -z "$out" ] && ok "rules: no stack, silent" || bad "rules: no stack, silent (exit $code)" "$out"
out=$(in_repo gate); check "gate: no stack, silent" "$out" '.' absent

echo '{"name":"x","scripts":{}}' > "$T/r/package.json"
out=$(in_repo nonsense); check "an unknown tier: usage" "$out" '^usage: enforce\.sh'
out=$(in_repo rules)
if jq -e '.hookSpecificOutput.hookEventName == "SessionStart" and (.hookSpecificOutput.additionalContext | test("stack: node"))' <<<"$out" >/dev/null 2>&1
then ok "rules: node, a SessionStart context naming the stack"; else bad "rules: node, a SessionStart context naming the stack" "$out"; fi
check "rules: advisory by default" "$out" 'Advisory in this repo'
echo '{"blocking": true, "coverage": 80}' > "$T/r/.kheona.json"
out=$(in_repo rules)
check "rules: blocking and the floor are announced" "$out" 'Enforced, not advisory.*coverage below the floor'
check "rules: the floor's number" "$out" 'floor 80%'
echo '{"phase": "bootstrap"}' > "$T/r/.kheona.json"
check "rules: the bootstrap phase" "$(in_repo rules)" 'K4 bootstrap phase'
rm "$T/r/.kheona.json"

mkdir -p "$T/r/src"
printf 'console.log("token", token);\n' > "$T/r/src/a.ts"
out=$(in_repo fast "$T/r/src/a.ts")
check "fast: a secret in a log statement" "$out" 'K5\.2'
check "fast: a PostToolUse context" "$out" '"hookEventName":"PostToolUse"'
printf '// @ts-ignore\nexport const x = 1;\n' > "$T/r/src/b.ts"
check "fast: a ts suppression without a reason" "$(in_repo fast "$T/r/src/b.ts")" 'K3\.2'
printf '// @ts-ignore why: the vendor type is wrong\nexport const x = 1;\n' > "$T/r/src/b.ts"
check "fast: ... with a reason, nothing" "$(in_repo fast "$T/r/src/b.ts")" '.' absent
printf 'export const C = () => <button>x</button>;\n' > "$T/r/src/c.tsx"
check "fast: no designSystem block, no design-system check" "$(in_repo fast "$T/r/src/c.tsx")" '.' absent
echo '{"designSystem":{"allow":{"element":["src/ui/*"]}}}' > "$T/r/.kheona.json"
check "fast: designSystem declared, a raw <button>" "$(in_repo fast "$T/r/src/c.tsx")" 'K3\.6 .*raw <button>'
mkdir -p "$T/r/src/ui"; cp "$T/r/src/c.tsx" "$T/r/src/ui/button.tsx"
check "fast: ... allowed in the file that defines it" "$(in_repo fast "$T/r/src/ui/button.tsx")" '.' absent
echo '{"tiers":{"fast":false}}' > "$T/r/.kheona.json"
check "fast: switched off with tiers.fast false" "$(in_repo fast "$T/r/src/a.ts")" '.' absent
rm "$T/r/.kheona.json"

mkdir -p "$T/r/.github/workflows"; echo 'name: x' > "$T/r/.github/workflows/kskill-pr.yml"
check "fast: an edited caller" "$(in_repo fast "$T/r/.github/workflows/kskill-pr.yml")" 'K2\.10 .*generated caller'
mkdir -p "$T/r/scripts"; : > "$T/r/scripts/kskill-callers.mjs"
check "fast: ... not in kheona-skill itself" "$(in_repo fast "$T/r/.github/workflows/kskill-pr.yml")" '.' absent

newrepo; mkdir -p "$T/r/lib/features" "$T/r/lib/core/config"; echo 'name: app' > "$T/r/pubspec.yaml"
printf "const e = String.fromEnvironment('X');\n" > "$T/r/lib/features/a.dart"
check "fast: flutter, a build define outside lib/core/config" "$(in_repo fast "$T/r/lib/features/a.dart")" 'K3\.6 .*lib/core/config'
cp "$T/r/lib/features/a.dart" "$T/r/lib/core/config/app_config.dart"
check "fast: ... inside it, nothing" "$(in_repo fast "$T/r/lib/core/config/app_config.dart")" '.' absent

echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
