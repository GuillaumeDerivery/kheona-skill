#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline test of scripts/kskill-renovate-plan.sh: GitHub's API is a stub `curl` on PATH. The configuration it writes
# must carry the App's login and commit identity (Renovate finds its Dependency Dashboard by that login).
set -uo pipefail
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "0 passed, 0 failed (skipped: the script needs bash 4+)"; exit 0; }
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else failn=$((failn+1)); echo "FAIL $1 (expected \"$3\", got \"$2\")"; fi; }
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do u=$a; done
case "$u" in
  */users/example-app%5Bbot%5D) echo '{"id": 4242}' ;;
  */contents/package.json) echo '{"dependencies": {"left-pad": "1.0.0"}}' ;;
  */contents/.gitmodules) exit 22 ;;
  *) exit 22 ;;
esac
STUB
chmod +x "$T/bin/curl"
echo '{"owner": "t1", "other": "t2"}' > "$T/tokens.json"
out=$(PATH="$T/bin:$PATH" KSKILL_BOT='example-app[bot]' KSKILL_LIB_REPO=owner/lib KSKILL_APP_TOKENS="$T/tokens.json" \
  REPOSITORIES='owner/repo other/repo' DRY_RUN=full bash "$HERE/scripts/kskill-renovate-plan.sh" "$T/out" 2>&1); rc=$?
check "exits 0" "$rc" 0
check "owners" "$(cat "$T/out/owners.json" 2>/dev/null)" '["other","owner"]'
check "username" "$(jq -r .username "$T/out/renovate-owner.json" 2>/dev/null)" 'example-app[bot]'
check "gitAuthor" "$(jq -r .gitAuthor "$T/out/renovate-owner.json" 2>/dev/null)" 'example-app[bot] <4242+example-app[bot]@users.noreply.github.com>'
check "npm may fetch git dependencies (the shared configs, and lib's own reference to them)" "$(jq -c "[.npmrc, .npmrcMerge]" "$T/out/renovate-owner.json" 2>/dev/null)" '["allow-git=all\n",true]'
check "repositories" "$(jq -c .repositories "$T/out/renovate-owner.json" 2>/dev/null)" '["owner/repo"]'
check "dry run" "$(jq -r .dryRun "$T/out/renovate-owner.json" 2>/dev/null)" full
# kheona-skill's PR writes the callers again: one command, allowed exactly, run once per branch.
cmd=$(jq -r '.packageRules[0].postUpgradeTasks.commands[0]' "$T/out/renovate-owner.json" 2>/dev/null)
check "post-upgrade: kheona-skill's PR, once per branch" "$(jq -c '.packageRules[0] | [.matchDepNames, .postUpgradeTasks.executionMode]' "$T/out/renovate-owner.json" 2>/dev/null)" '[["/(^|/)kheona-skill(/|$)/"],"branch"]'
check "... the command is allowed, exactly" "$(CMD=$cmd RX=$(jq -r '.allowedCommands | join("\n")' "$T/out/renovate-owner.json") node -e '
  const rx = process.env.RX.split("\n"); console.log(rx.length + ":" + rx.every((r) => new RegExp(r).test(process.env.CMD)) + ":" + new RegExp(rx[0]).test(process.env.CMD + " && true"))')" '1:true:false'
check "... no template braces, one quoted argument" "$(grep -c '{{' <<<"$cmd"):$(tr -cd "'" <<<"$cmd" | wc -c | tr -d ' ')" '0:2'
# Run it as Renovate does (shlex-split, no shell), on a repository whose callers Renovate just moved from an older
# generation (a per-stack main, the stack named): fetch serves this checkout's files.
OLD=0123456789abcdef0123456789abcdef01234567; NEW=89abcdef0123456789abcdef0123456789abcdef
R=$T/repo; mkdir -p "$R/.github/workflows"; echo '{}' > "$R/package.json"; echo '{"role":"project"}' > "$R/.kheona.json"
node "$HERE/scripts/kskill-callers.mjs" write --repo "$R" --self owner/kheona-skill --sha $OLD --version v1.0.0 > /dev/null
sed -i.bak "s|kskill-main.yml@$OLD|kskill-main-service.yml@$OLD|; s|^    uses: \(.*\)$|&\n    with:\n      stack: node|" "$R/.github/workflows/kskill-main.yml"; rm -f "$R"/.github/workflows/*.bak
for f in "$R"/.github/workflows/*.yml; do sed -i.bak "s/$OLD # v1.0.0/$NEW # v1.1.0/; s/at v1.0.0\./at v1.1.0./" "$f"; rm -f "$f.bak"; done
cat > "$T/fetch.mjs" <<'JS'
import { readFileSync } from 'node:fs';
globalThis.fetch = async (url) => {
  const m = String(url).match(/^https:\/\/raw\.githubusercontent\.com\/owner\/kheona-skill\/[0-9a-f]{40}\/(.+)$/);
  if (!m) return { ok: false, status: 404 };
  const body = readFileSync(`${process.env.KSKILL_TEST_HOME}/${m[1]}`, 'utf8');
  return { ok: true, status: 200, text: async () => body };
};
JS
argv=$(CMD=$cmd python3 -c 'import os, shlex, json; print(json.dumps(shlex.split(os.environ["CMD"])))')
out=$(cd "$R" && KSKILL_TEST_HOME=$HERE NODE_OPTIONS="--import=$T/fetch.mjs" node -e '
  const [cmd, ...args] = JSON.parse(process.argv[1]);
  const r = require("child_process").spawnSync(cmd, args, { stdio: "inherit" }); process.exit(r.status);' "$argv" 2>&1); rc=$?
check "... runs" "$rc" 0
check "... main is written again, at the new pin, no stack named" "$(grep -c "kskill-main.yml@$NEW # v1.1.0" "$R/.github/workflows/kskill-main.yml"):$(grep -c 'stack:' "$R/.github/workflows/kskill-main.yml")" '1:0'
node "$HERE/scripts/kskill-callers.mjs" check --repo "$R" --self owner/kheona-skill >/dev/null 2>&1; check "... and the callers rule passes" "$?" 0
PATH="$T/bin:$PATH" KSKILL_LIB_REPO=owner/lib KSKILL_APP_TOKENS="$T/tokens.json" REPOSITORIES=owner/repo \
  bash "$HERE/scripts/kskill-renovate-plan.sh" "$T/out2" >/dev/null 2>&1; rc=$?
check "KSKILL_BOT required" "$([ $rc -ne 0 ] && echo refused)" refused
# A run behind the latest release says so (v2.7.0's PRs were opened by a caller still on v2.6.1, whose plan has no
# regeneration): KSKILL_SHA is compared with the latest release; the stub says it is 3 commits ahead, then 0.
for ahead in 3 0; do
  cat > "$T/bin/curl" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do u=\$a; done
case "\$u" in
  */users/example-app%5Bbot%5D) echo '{"id": 4242}' ;;
  */repos/owner/kheona-skill/releases/latest) echo '{"tag_name": "v9.9.9"}' ;;
  */repos/owner/kheona-skill/compare/0123456789abcdef0123456789abcdef01234567...v9.9.9) echo '{"ahead_by": $ahead}' ;;
  */contents/package.json) echo '{"dependencies": {"left-pad": "1.0.0"}}' ;;
  *) exit 22 ;;
esac
STUB
  lag=$(PATH="$T/bin:$PATH" KSKILL_REPO=owner/kheona-skill KSKILL_SHA=0123456789abcdef0123456789abcdef01234567 KSKILL_BOT='example-app[bot]' \
    KSKILL_LIB_REPO=owner/lib KSKILL_APP_TOKENS="$T/tokens.json" REPOSITORIES=owner/repo bash "$HERE/scripts/kskill-renovate-plan.sh" "$T/out-$ahead" 2>&1); rc=$?
  check "behind the latest release by $ahead: exits 0" "$rc" 0
  check "... a warning naming it: $([ "$ahead" -gt 0 ] && echo yes || echo no)" "$(grep -c '^::warning::.*3 commit(s) behind its latest release v9.9.9' <<<"$lag")" "$([ "$ahead" -gt 0 ] && echo 1 || echo 0)"
done
check "no KSKILL_SHA (or no release reachable): no warning, still planned" "$(grep -c '::warning::' <<<"$out"):$(jq -c .repositories "$T/out/renovate-owner.json" 2>/dev/null)" '0:["owner/repo"]'
[ $failn -eq 0 ] || echo "$out"
echo "$pass passed, $failn failed"; [ $failn -eq 0 ]
