#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# kskill-checkout-submodules.sh: the URL git clones a submodule from carries the token, even when the global config
# already rewrites git@github.com: to https://github.com/ (kskill-app-tokens.mjs --install does). No network: a git
# wrapper prints the URL `git submodule update` would fetch.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0 failed=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1 (got: $2)"; fi; }

REAL=$(command -v git)
mkdir -p "$T/bin" "$T/repo"
cat > "$T/bin/git" <<SH
#!/usr/bin/env bash
case "\$1 \${2:-}" in
  "submodule update") "$REAL" ls-remote --get-url git@github.com:Org/lib.git; "$REAL" ls-remote --get-url https://github.com/Org/lib.git ;;
  "submodule "*) ;;
  *) exec "$REAL" "\$@" ;;
esac
SH
chmod +x "$T/bin/git"
printf '[submodule "lib"]\n\tpath = lib\n\turl = git@github.com:Org/lib.git\n' > "$T/repo/.gitmodules"
printf '[url "https://github.com/"]\n\tinsteadOf = git@github.com:\n' > "$T/global"

run() { (cd "$T/repo" && PATH="$T/bin:$PATH" GIT_CONFIG_GLOBAL="$T/global" SUBMODULE_TOKEN=tok bash "$HERE/.github/scripts/kskill-checkout-submodules.sh" 2>&1); }

out=$(run); rc=$?
check "exit 0" "$rc" '^0$'
check "SSH URL: the token, despite the global rewrite" "$(sed -n 1p <<<"$out")" '^https://x-access-token:tok@github\.com/Org/lib\.git$'
check "HTTPS URL: the token" "$(sed -n 2p <<<"$out")" '^https://x-access-token:tok@github\.com/Org/lib\.git$'
out=$(cd "$T/repo" && PATH="$T/bin:$PATH" GIT_CONFIG_GLOBAL="$T/global" bash "$HERE/.github/scripts/kskill-checkout-submodules.sh" 2>&1); rc=$?
check "no SUBMODULE_TOKEN: exit 1" "$rc" '^1$'

echo "checkout-submodules: $pass passed, $failed failed"
[ "$failed" = 0 ]
