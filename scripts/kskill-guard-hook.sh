#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The guard on your own machine, so nothing private leaves it. Same guard and list as CI's `rule-0`.
#
#   kskill-guard-hook.sh install <list>   in a clone: git hooks pre-commit, commit-msg and pre-push; remembers the list
#                                         (git config --global kheona.guardList) and the repository
#                                         (git config --global kheona.guarded owner/name), which `claude` reads.
#   kskill-guard-hook.sh pre-commit       the tracked files
#   kskill-guard-hook.sh commit-msg FILE  the message
#   kskill-guard-hook.sh pre-push         the commits not yet on the remote
#   kskill-guard-hook.sh claude           a Claude Code PreToolUse hook on Bash: reads the tool call on stdin and denies a
#                                         git or gh command aimed at a guarded repository whose text, body file or
#                                         pushed commits hold a term. Silent when nothing is configured.
# The list: KSKILL_GUARD_LIST, else git config kheona.guardList. A hook with no list refuses (the guard exits 64).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
guard="$here/.github/scripts/kskill-guard.mjs"
list() { printf '%s' "${KSKILL_GUARD_LIST:-$(git config --get kheona.guardList 2>/dev/null)}"; }
self_of() { git -C "$1" remote get-url origin 2>/dev/null | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##'; }
run_guard() { # run_guard <clone> <guard args...>
  local root=$1; shift
  KSKILL_GUARD_LIST=$(list) node "$root/.github/scripts/kskill-guard.mjs" --repo "$root" --self "$(self_of "$root")" "$@"
}

case "${1:-}" in
  install)
    [ -n "${2:-}" ] && [ -f "$2" ] || { echo "usage: $0 install <list file>" >&2; exit 64; }
    root=$(git rev-parse --show-toplevel) || exit 64
    hooks=$(git -C "$root" rev-parse --git-path hooks); case $hooks in /*) ;; *) hooks="$root/$hooks" ;; esac
    mkdir -p "$hooks"
    for h in pre-commit commit-msg pre-push; do
      if [ -e "$hooks/$h" ] && ! grep -q kskill-guard-hook "$hooks/$h"; then echo "$hooks/$h exists and is not ours: left as is" >&2; continue; fi
      printf '#!/usr/bin/env bash\nexec bash "$(git rev-parse --show-toplevel)/scripts/kskill-guard-hook.sh" %s "$@"\n' "$h" > "$hooks/$h"
      chmod +x "$hooks/$h"
    done
    path=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
    git config --global kheona.guardList "$path"
    self=$(self_of "$root")
    [ -z "$self" ] || git config --global --get-all kheona.guarded 2>/dev/null | grep -qixF "$self" || git config --global --add kheona.guarded "$self"
    echo "guard hooks installed in $hooks; list $path; guarded ${self:-<no origin>}"
    ;;
  pre-commit) run_guard "$(git rev-parse --show-toplevel)" ;;
  commit-msg) run_guard "$(git rev-parse --show-toplevel)" --no-files --text-file "$2" ;;
  pre-push)
    root=$(git rev-parse --show-toplevel)
    # stdin: <local ref> <local sha> <remote ref> <remote sha> per ref pushed
    rc=0
    while read -r _ lsha _ rsha; do
      [ "$lsha" = 0000000000000000000000000000000000000000 ] && continue
      if [ "$rsha" != 0000000000000000000000000000000000000000 ]; then range="$rsha..$lsha"
      else base=$(git -C "$root" merge-base "$lsha" origin/HEAD 2>/dev/null) && range="$base..$lsha" || range=$lsha; fi
      run_guard "$root" --no-files --commits "$range" || rc=1
    done
    run_guard "$root" || rc=1
    exit $rc
    ;;
  claude)
    input=$(cat)
    l=$(list); [ -n "$l" ] && [ -f "$l" ] || exit 0
    guarded=$(git config --global --get-all kheona.guarded 2>/dev/null) || exit 0
    cmd=$(jq -r '.tool_input.command // empty' <<<"$input"); cwd=$(jq -r '.cwd // empty' <<<"$input")
    grep -qE '(^|[;&|( ]|\$\()(git|gh)( |$)' <<<"$cmd" || exit 0
    # The clone a command acts in: its cwd, a `cd DIR` or a `git -C DIR`.
    target='' clone=''
    for d in "$cwd" $(grep -oE '(cd|-C) +[^ ;&|)]+' <<<"$cmd" | awk '{print $2}'); do
      d=${d/#\~/$HOME}; r=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || continue
      s=$(self_of "$r"); grep -qixF "$s" <<<"$guarded" && { target=$s; clone=$r; }
    done
    # Or it names a guarded repository (exactly: not a longer name that starts the same).
    while read -r g; do
      [ -n "$g" ] && grep -qiE "(^|[^A-Za-z0-9_.-])${g//./\\.}([^A-Za-z0-9_.-]|$)" <<<"$cmd" && target=$g
    done <<<"$guarded"
    [ -n "$target" ] || exit 0
    T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
    printf '%s\n' "$cmd" > "$T/command"
    files=(--text-file "$T/command")
    for f in $(grep -oE '(--body-file|-F|--file) +[^ ;&|)]+' <<<"$cmd" | awk '{print $2}'); do
      f=${f/#\~/$HOME}; case $f in /*) ;; *) f="${cwd:-.}/$f" ;; esac; [ -f "$f" ] && files+=(--text-file "$f")
    done
    out=$(KSKILL_GUARD_LIST=$l node "$guard" --repo "${clone:-$here}" --self "$target" --no-files "${files[@]}" 2>&1) || hit=1
    if [ -n "$clone" ] && grep -qE 'git( -C [^ ]+)? push' <<<"$cmd"; then
      up=$(git -C "$clone" rev-parse --verify -q '@{u}' >/dev/null && echo '@{u}..HEAD' || echo 'origin/HEAD..HEAD')
      out+=$'\n'$(KSKILL_GUARD_LIST=$l node "$guard" --repo "$clone" --self "$target" --commits "$up" 2>&1) || hit=1
    fi
    [ -z "${hit:-}" ] && exit 0
    reason="kskill-guard: this command would put a private term in $target. $(grep -vE '^guard:' <<<"$out" | sed -E "s#$T/##" | tr '\n' ' ')"
    jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    ;;
  *) sed -n '4,15p' "$0" >&2; exit 64 ;;
esac
