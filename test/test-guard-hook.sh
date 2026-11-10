#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The local guard: git hooks in a throwaway clone, and the Claude Code hook on a fake tool call.
set -uo pipefail
unset GITHUB_ACTIONS KSKILL_GUARD_LIST
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME=$T/home GIT_CONFIG_GLOBAL=$T/home/.gitconfig GIT_CONFIG_NOSYSTEM=1; mkdir -p "$HOME"; touch "$GIT_CONFIG_GLOBAL"
pass=0 failed=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1 (got: $2)"; fi; }
printf 'SecretCorp\n' > "$T/list"
git init -q --bare "$T/remote.git"
git clone -q "$T/remote.git" "$T/c" 2>/dev/null; C=$T/c
git -C "$C" config user.email a@example.com; git -C "$C" config user.name a; git -C "$C" config commit.gpgsign false
git -C "$C" remote set-url origin https://github.com/owner/kheona-skill.git
git -C "$C" remote add local "$T/remote.git"
mkdir -p "$C/scripts" "$C/.github/scripts"
cp "$HERE/scripts/kskill-guard-hook.sh" "$HERE/scripts/kskill-guard-command.mjs" "$C/scripts/"; cp "$HERE/.github/scripts/kskill-guard.mjs" "$C/.github/scripts/"
echo clean > "$C/a.txt"; git -C "$C" add -A; git -C "$C" commit -qm first --no-verify

out=$(cd "$C" && bash scripts/kskill-guard-hook.sh install "$T/list" 2>&1); rc=$?
check "install: exit 0" "$rc" '^0$'
check "install: the three hooks" "$(for h in pre-commit commit-msg pre-push; do [ -x "$C/.git/hooks/$h" ] && printf '%s ' "$h"; done)" '^pre-commit commit-msg pre-push $'
check "install: the list and the repository remembered" "$(git config --global kheona.guardList) $(git config --global kheona.guarded)" "^$T/list owner/kheona-skill$"
(cd "$C" && bash scripts/kskill-guard-hook.sh install "$T/list" >/dev/null 2>&1)
check "install twice: the repository once" "$(git config --global --get-all kheona.guarded | wc -l | tr -d ' ')" '^1$'

echo 'ask secretcorp' > "$C/b.txt"; git -C "$C" add -A
out=$(git -C "$C" commit -qm second 2>&1); rc=$?
check "pre-commit: a term in a file stops the commit" "$rc $out" '^1 .*b\.txt:1: 1 forbidden'
check "... the term is never printed" "$( [[ $out == *ecret* ]] && echo leaked || echo clean )" '^clean$'
echo fine > "$C/b.txt"; git -C "$C" add -A
out=$(git -C "$C" commit -qm 'about SecretCorp' 2>&1); rc=$?
check "commit-msg: a term in the message stops the commit" "$rc" '^1$'
out=$(git -C "$C" commit -qm 'owner/kheona-skill: fine' 2>&1); rc=$?
check "commit-msg: the repository naming itself passes" "$rc" '^0$'
git -C "$C" commit -q --allow-empty --no-verify -m 'leak SecretCorp'
out=$(git -C "$C" push -q local HEAD:main 2>&1); rc=$?
check "pre-push: a commit holding a term is not pushed" "$rc" '^[1-9]'
git -C "$C" reset -q --hard HEAD~1
out=$(git -C "$C" push -q local HEAD:main 2>&1); rc=$?
check "pre-push: clean commits go" "$rc $out" '^0'

hook() { jq -n --arg c "$1" --arg d "${2:-$T}" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' | bash "$C/scripts/kskill-guard-hook.sh" claude; }
check "claude: unrelated command, silent" "$(hook 'ls -la')" '^$'
check "claude: another repository, silent" "$(hook 'gh pr create --repo owner/other --title "SecretCorp"')" '^$'
check "claude: a longer name that starts the same, silent" "$(hook 'gh pr create --repo owner/kheona-skill-next --title "SecretCorp"')" '^$'
out=$(hook 'gh pr create --repo owner/kheona-skill --title "fix: SecretCorp"')
check "claude: a PR title on the guarded repository is denied" "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" '^deny$'
check "... the term is never printed" "$( [[ $out == *ecret* ]] && echo leaked || echo clean )" '^clean$'
check "claude: a read-only gh command naming a term passes" "$(hook 'gh run view 1 --repo owner/kheona-skill --log | grep SecretCorp')" '^$'
check "claude: a read-only command in the clone passes" "$(hook 'git log --grep SecretCorp' "$C")" '^$'
check "claude: gh api sending a field is a write" "$(hook "gh api repos/owner/kheona-skill/issues -f title=SecretCorp" | jq -r .hookSpecificOutput.permissionDecision)" '^deny$'
check "claude: a reader before a clean write is not checked" "$(hook 'cd /x/SecretCorp && grep -r a . | head; gh pr merge 5 --repo owner/kheona-skill')" '^$'
check "claude: a value set before the write is checked" "$(hook 'x=SecretCorp; gh pr create --repo owner/kheona-skill --title "$x"' | jq -r .hookSpecificOutput.permissionDecision)" '^deny$'
check "claude: data piped into the write is checked" "$(hook 'echo SecretCorp | gh pr comment 1 --repo owner/kheona-skill --body-file -' | jq -r .hookSpecificOutput.permissionDecision)" '^deny$'
check "claude: a heredoc body with separators stays whole" "$(hook "gh pr create --repo owner/kheona-skill --body \"\$(cat <<'EOF'
a; b && c
SecretCorp
EOF
)\"" | jq -r .hookSpecificOutput.permissionDecision)" '^deny$'
check "claude: a file written before the write is checked" "$(hook "cat > b.md <<'EOF'
SecretCorp
EOF
gh pr create --repo owner/kheona-skill --body-file b.md" | jq -r .hookSpecificOutput.permissionDecision)" '^deny$'
check "claude: a clean PR passes" "$(hook 'gh pr create --repo owner/kheona-skill --title "fix: a thing"')" '^$'
echo 'body SecretCorp' > "$T/body.md"
check "claude: a body file is read" "$(hook "gh pr create --repo owner/kheona-skill --body-file $T/body.md" | jq -r .hookSpecificOutput.permissionDecision)" '^deny$'
check "claude: a commit in the clone (cwd) is denied" "$(hook 'git commit -m "SecretCorp"' "$C" | jq -r .hookSpecificOutput.permissionDecision)" '^deny$'
check "claude: git -C the clone too" "$(hook "git -C $C commit -m 'SecretCorp'" | jq -r .hookSpecificOutput.permissionDecision)" '^deny$'
git -C "$C" commit -q --allow-empty --no-verify -m 'leak SecretCorp'
git -C "$C" branch -q -u local/main 2>/dev/null || git -C "$C" fetch -q local && git -C "$C" branch -q -u local/main
check "claude: a push carrying a commit with a term is denied" "$(hook 'git push' "$C" | jq -r .hookSpecificOutput.permissionDecision)" '^deny$'
git config --global --unset-all kheona.guardList
check "claude: no list configured, silent" "$(hook 'gh pr create --repo owner/kheona-skill --title SecretCorp')" '^$'

echo "guard-hook: $pass passed, $failed failed"; [ "$failed" = 0 ]
