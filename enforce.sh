#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Kheona K-rule enforcement, as Claude Code hooks (SKILL.md, Enforcement). Detects the stack, runs the tier, reports.
#
# Tiers:
#   fast <file>  advisory  — per-file invariants + secret-in-log. Sub-second. PostToolUse.
#   gate         BLOCKING  — format + lint + typecheck. Seconds. PreToolUse on git commit.
#   full         BLOCKING  — gate + the test suite, plus the coverage floor on the stacks
#                            that can enforce one. Slow. PreToolUse on git push.
#   rules        context   — inject the K-rule digest. SessionStart.
#
# Per-repo config, optional, at the repo root as .kheona.json:
#   { "coverage": 90, "tiers": { "fast": true, "gate": true, "full": true },
#     "designSystem": {
#       "allow": { "button": ["lib/core/widgets/app_buttons.dart"], ... },
#       "invariants": [ { "name": "...", "pattern": "...", "allow": [...], "message": "..." } ] } }
# K3.3-K3.6 (design system): the CHECKS are built in per stack, the ALLOW-LIST is per repo.
# Allow-list entries are globs matched against the repo-relative path ("*webview*" works).
# No "designSystem" block => the design-system checks do not run, and `gate` says so once.
# That is deliberate: a built-in allow-list of one repo's filenames passes there and fails
# everywhere else, which is worse than no check. Declaring the block is the repo stating
# which files ARE its design system.
# K4.4 (ratchet): set "coverage" to today's measured number, raise it as tests land.
# The FLOOR is opt-in; running the tests is not. `full` always runs the suite, and an absent
# "coverage" key drops the threshold, never the test run. Until 2026-09-21 the absent key
# skipped tier_full altogether, so `git push` ran format/lint/typecheck and nothing else
# while the SessionStart banner said the suite was gated. A gate nobody runs is worse than none.
# Not every stack can enforce a floor. Flutter has none by design (stacks/flutter.md K4.2),
# and Node applies it with c8 check-coverage, which needs the repo to expose a "coverage"
# script. Where the number cannot be enforced the key FAILS loudly rather than passing.
# K4 bootstrap phase ("phase": "bootstrap" in .kheona.json; absent = "established"): `full` runs the tests that
# exist (none yet is not a failure) and reports the floor instead of failing on it, as the CI does; the notes say
# "deferred (bootstrap)". The phase must be "established" before the first production release (CI refuses it).

set -uo pipefail
TIER="${1:-}"; FILE="${2:-}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$ROOT" || exit 0

CFG="$ROOT/.kheona.json"
cfg() { [ -f "$CFG" ] && jq -r "$1 // empty" "$CFG" 2>/dev/null; }
# enabled <tier> — false only when the repo explicitly switched that tier off.
# Not via cfg(): jq's `//` treats `false` exactly like absent, so `.tiers.full // empty`
# came back empty for a tier set to false and every tier read as enabled — the keys have
# never been able to switch one off. Ask the question as a comparison instead.
enabled() {
  [ -f "$CFG" ] || return 0
  ! jq -e --arg t "$1" '.tiers[$t] == false' "$CFG" >/dev/null 2>&1
}
# Advisory by default: findings are reported, nothing is denied. A repo opts into
# hard blocking with {"blocking": true} in .kheona.json — do that only once its
# gate already passes, or every commit is denied until someone rips the hook out.
blocking() { [ "$(cfg '.blocking')" = "true" ] || [ "${KHEONA_BLOCKING:-}" = "1" ]; }

# has_script <name> — true when package.json declares that npm script. Used by the node
# coverage floor, which is applied to a report the repo itself has to produce.
has_script() {
  [ -f package.json ] || return 1
  jq -e --arg s "$1" '.scripts[$s] // empty' package.json >/dev/null 2>&1
}

# ---- K3.3-K3.6 design-system helpers ---------------------------------------
# REL is set per-file in tier_fast. Every allow-list is a repo's own declaration; nothing
# here knows any repo's filenames.
ds_configured() { [ -n "$(cfg '.designSystem')" ]; }

# _glob_allowed <jq path yielding globs> — true when REL matches any of them.
_glob_allowed() {
  local pat
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254  # why: $pat is a glob from .kheona.json, matched as a pattern on purpose
    case "$REL" in $pat) return 0 ;; esac
  done < <(cfg "$1")
  return 1
}

# ds_check <name> <extended-regex> <message> — a built-in invariant, skipped when this
# repo declares the file as the one that defines the primitive.
ds_check() {
  _glob_allowed ".designSystem.allow[\"$1\"][]?" && return 0
  grep -nE "$2" "$FILE" >/dev/null 2>&1 && fail "K3.6 — $3"
  return 0
}

# ds_custom — repo-specific invariants declared in .kheona.json, same shape.
ds_custom() {
  local n i name re msg
  n="$(cfg '.designSystem.invariants | length')"
  [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null || return 0
  for ((i = 0; i < n; i++)); do
    re="$(cfg ".designSystem.invariants[$i].pattern")"
    [ -n "$re" ] || continue
    _glob_allowed ".designSystem.invariants[$i].allow[]?" && continue
    name="$(cfg ".designSystem.invariants[$i].name")"
    msg="$(cfg ".designSystem.invariants[$i].message")"
    grep -nE "$re" "$FILE" >/dev/null 2>&1 \
      && fail "K3.6 — ${msg:-"invariant \"${name:-$i}\" matched in this file."}"
  done
}

# has_ui — does this repo render anything? Flutter always does; a node package only when
# it has component files. Used by `gate` to decide whether a missing designSystem block
# is a finding or simply irrelevant.
has_ui() {
  case "$STACK" in
    flutter) return 0 ;;
    static)  return 0 ;;
    node)    find src app components -name '*.tsx' -o -name '*.jsx' 2>/dev/null | head -1 | grep -q . ;;
    *)       return 1 ;;
  esac
}

# ---- stack detection -------------------------------------------------------
stack() {
  [ -f pubspec.yaml ]                  && { echo flutter;    return; }
  [ -f Pipfile ] || [ -f pyproject.toml ] && { echo python; return; }
  [ -f package.json ]                  && { echo node;       return; }
  ls ./*.tf >/dev/null 2>&1            && { echo terraform;  return; }
  [ -f wrangler.toml ] || [ -f wrangler.jsonc ] && { echo static; return; }
  echo none
}
STACK="$(stack)"
[ "$STACK" = none ] && [ "$TIER" != rules ] && exit 0

FAILS=""
REL=""
fail() { FAILS="${FAILS}${FAILS:+$'\n'}- $1"; }
# defer <msg>: a K4 item the bootstrap phase reports without failing on.
defer() { NOTES="${NOTES}${NOTES:+$'\n'}- deferred (bootstrap): $1"; }
NOTES=""
bootstrap() { [ "$(cfg '.phase')" = bootstrap ]; }
OUT="$(mktemp "${TMPDIR:-/tmp}/kheona.XXXXXX")"; trap 'rm -f "$OUT"' EXIT
run()  { "$@" >"$OUT" 2>&1; }   # quiet; caller decides what to surface

# ---- tier: fast (advisory, per touched file) -------------------------------
tier_fast() {
  [ -n "$FILE" ] && [ -f "$FILE" ] || exit 0
  case "$FILE" in */node_modules/*|*/build/*|*/.dart_tool/*|*/generated/*) exit 0 ;; esac
  # The repository-relative path. Resolve symlinks first: git prints the physical root (/private/var/... on macOS)
  # while the hook may pass a path through a symlink (/var/...).
  FILE="$(cd "$(dirname "$FILE")" && pwd -P)/$(basename "$FILE")"
  REL="${FILE#"$ROOT"/}"

  # K2.10 — a repository's .github/workflows/kskill-*.yml are callers generated by kheona-skill's
  # scripts/kskill-callers.mjs; an edit fails `kskill-callers.mjs check` in CI. Not in kheona-skill itself,
  # where those files are the shared workflows.
  if [ ! -f "$ROOT/scripts/kskill-callers.mjs" ]; then
    case "$REL" in
      .github/workflows/kskill-*)
        fail "K2.10 — $REL is a generated caller. Revert this edit: change .kheona.json and regenerate with kheona-skill's scripts/kskill-callers.mjs write, or change the shared workflow in kheona-skill." ;;
    esac
  fi

  # K5.2 — sensitive values in log statements, every stack
  if grep -nEi '(print|debugPrint|console\.(log|info|debug)|logger\.(info|debug)|fmt\.Print)' "$FILE" 2>/dev/null \
     | grep -iE 'token|password|passwd|secret|api[_-]?key|\bpan\b|\bcvv\b|authorization' >/dev/null; then
    fail "K5.2 — a log statement in this file names a token/password/secret/PAN/CVV. Gate it behind a debug flag or drop the value."
  fi

  case "$STACK" in
    flutter)
      case "$FILE" in
        */ios/Podfile|*/ios/Podfile.lock)
          fail "K1.4 — CocoaPods must not be used. Do not create a Podfile; this project is Swift Package Manager only." ;;
      esac
      case "$FILE" in *.dart) ;; *) [ -n "$FAILS" ] || exit 0 ;; esac
      # App configuration constants (stacks/flutter.md): the app's configuration lives in lib/core/config/ only.
      # A fixed location, not a per-repo allow-list, so it runs with or without a designSystem block.
      case "$REL" in
        lib/core/config/*) ;;
        lib/*)
          grep -nE '(String|bool|int)\.fromEnvironment\(|dotenv' "$FILE" >/dev/null 2>&1 \
            && fail "K3.6 — a build-time define or dotenv read outside lib/core/config/. App configuration is a static const in lib/core/config/app_config.dart; import it from there (stacks/flutter.md, App configuration constants)." ;;
      esac
      if ds_configured; then
        ds_check button   '(^|[^A-Za-z])(ElevatedButton|TextButton)\(' \
          "raw ElevatedButton/TextButton. Use the design system's button component, or add the parameter it is missing (K3.4)."
        ds_check dropdown 'DropdownButtonFormField\(' \
          "raw DropdownButtonFormField. Use the design system's dropdown field."
        ds_check dialog   'AlertDialog\(' \
          "raw AlertDialog. Use the design system's dialog component."
        ds_check color    '(^|[^A-Za-z])Colors\.(black|white)' \
          "literal Colors.black/white. Use a colour token."
        ds_check shadow   'BoxShadow\(' \
          "hand-written BoxShadow. Use the elevation token."
        ds_custom
      fi
      ;;
    node)
      case "$FILE" in *.ts|*.tsx|*.jsx|*.css) ;; *) return ;; esac  # return, not exit: keep the findings above
      case "$FILE" in *.ts|*.tsx)
        grep -nE '@ts-ignore|@ts-expect-error' "$FILE" >/dev/null \
          && ! grep -nE '@ts-(ignore|expect-error).*(why|because)' "$FILE" >/dev/null \
          && fail "K3.2 — a ts suppression with no reason. Add 'why:' or fix the type."
        ;;
      esac
      if ds_configured; then
        case "$FILE" in
          *.tsx|*.jsx)
            ds_check element '<(button|input|select|textarea|dialog)[[:space:]/>]' \
              "a raw <button>/<input>/<select>/<dialog>. Use the design system's component."
            ds_check inline-style 'style=\{\{' \
              "an inline style object bypasses the token layer."
            ds_check arbitrary '(text|bg|border|shadow|rounded)-\[' \
              "an arbitrary Tailwind value is a literal wearing a utility class. Use a token."
            ;;
        esac
        ds_check color '#[0-9a-fA-F]{3}([0-9a-fA-F]{3})?\b' \
          "a literal hex colour outside the token layer."
        ds_custom
      fi
      ;;
    python)
      case "$FILE" in *.py) ;; *) return ;; esac
      grep -nE '^\s*except\s*:' "$FILE" >/dev/null \
        && fail "K3.2 — bare 'except:' swallows the failures K2.5 says must name themselves."
      ;;
    terraform)
      case "$FILE" in *.tf) ;; *) return ;; esac
      grep -n '0\.0\.0\.0/0' "$FILE" >/dev/null \
        && ! grep -nB2 '0\.0\.0\.0/0' "$FILE" | grep -q '#' \
        && fail "K4.5 — 0.0.0.0/0 with no comment justifying it."
      ;;
  esac
}

# ---- tier: gate (blocking; format + lint + typecheck) ----------------------
tier_gate() {
  # K3.3/K3.6 — a UI repo that never declared its design system runs no design-system
  # checks at all. Said once here rather than on every Write/Edit.
  if has_ui && ! ds_configured; then
    fail "K3.3/K3.6 — this repo renders a UI and has no \"designSystem\" block in .kheona.json, so none of the design-system invariants ran. Declare the files that define each primitive (button, dropdown, dialog, colour, shadow); see the kheona skill, Enforcement, and docs/kheona-json.md."
  fi
  case "$STACK" in
    flutter)
      { [ -f ios/Podfile ] || [ -f ios/Podfile.lock ] || [ -d ios/Pods ]; } \
        && fail "K1.4 — CocoaPods must not be used. Found a Podfile/Podfile.lock/Pods dir. Flutter iOS builds use Swift Package Manager only; see the kheona skill's stacks/flutter.md for the migration procedure."
      command -v flutter >/dev/null || return
      run flutter analyze          || fail "K3.2 — flutter analyze is not clean:"$'\n'"$(tail -20 "$OUT")"
      run dart format --output=none --set-exit-if-changed lib/ \
                                   || fail "K3.1 — dart format would change files under lib/. Run: dart format lib/"
      ;;
    node)
      [ -f tsconfig.json ] && { run npx --no-install tsc --noEmit || fail "K3.2 — tsc --noEmit failed:"$'\n'"$(tail -20 "$OUT")"; }
      run npx --no-install eslint . --max-warnings=0 || fail "K3.1 — eslint is not clean:"$'\n'"$(tail -20 "$OUT")"
      ;;
    python)
      run pipenv run black --check . || fail "K3.1 — black would reformat. Run: pipenv run black ."
      [ -f pylintrc ] && { run pipenv run pylint --rcfile=pylintrc . || fail "K3.1 — pylint is not clean:"$'\n'"$(tail -20 "$OUT")"; }
      ;;
    terraform)
      run terraform fmt -recursive -check || fail "K3.1 — terraform fmt would change files. Run: terraform fmt -recursive"
      run terraform validate              || fail "K3.2 — terraform validate failed:"$'\n'"$(tail -20 "$OUT")"
      ;;
  esac
}

# ---- tier: full (blocking; gate + tests + coverage) ------------------------
tier_full() {
  tier_gate
  local min; min="$(cfg '.coverage')"
  case "$STACK" in
    flutter)
      command -v flutter >/dev/null || return
      if bootstrap && [ ! -d test ]; then defer "K4.1 — no test/ directory yet."; return; fi
      run flutter test || { fail "K4.1 — the test suite is failing:"$'\n'"$(tail -25 "$OUT")"; return; }
      # No coverage check for Flutter, deliberately — see stacks/flutter.md K4.2.
      # `flutter test --coverage` omits any library no test imports, so its
      # percentage is inflated (measured ~4x on one repo: 10.9% reported against
      # 2.6% real). A floor over a denominator known to be wrong manufactures
      # false confidence, so the standard stopped asking Flutter for a number at
      # all rather than enforcing a bad one. A `.kheona.json` "coverage" key is
      # therefore inert on this stack; say so rather than ignoring it silently.
      if [ -n "$min" ]; then
        fail "K4.2 — .kheona.json sets \"coverage\": ${min}, which is ignored on Flutter. The standard no longer sets a Flutter coverage target (stacks/flutter.md K4.2); remove the key to avoid implying a gate that does not run."
      fi
      ;;
    node)
      if bootstrap && ! has_script test && ! has_script coverage; then defer "K4.1 — no test script yet."; return; fi
      # Bootstrap: a floor that cannot be measured yet is reported; the tests that exist still run.
      if bootstrap && [ -n "$min" ] && { ! has_script coverage || ! npx --no-install c8 --version >/dev/null 2>&1; }; then
        defer "K4.2 — the floor of ${min}% is not measured yet (no \"coverage\" script under c8)."; min=""
      fi
      if [ -z "$min" ]; then
        run npm test --silent || fail "K4.1 — the test suite is failing:"$'\n'"$(tail -25 "$OUT")"
        return
      fi
      # A floor was declared, so it gets measured. The repo owns HOW (stacks/node-ts.md K4.2):
      # a "coverage" script that runs the suite under c8, and c8 check-coverage applies the
      # number from .kheona.json to what that run produced — so the configured floor is the
      # floor enforced, not a second copy of one living in a script. Where either half is
      # missing the hook says so and fails; it does not quietly pass a repo it cannot measure.
      if ! has_script coverage; then
        fail "K4.2 — .kheona.json sets \"coverage\": ${min}, but package.json declares no \"coverage\" script, so nothing measures it and the floor is not enforced. Add one that runs the suite under c8 (\"coverage\": \"c8 <your test command>\", see stacks/node-ts.md K4.2), or remove the key."
        return
      fi
      if ! npx --no-install c8 --version >/dev/null 2>&1; then
        fail "K4.2 — .kheona.json sets \"coverage\": ${min}, but c8 is not installed in this repo and c8 check-coverage is the only threshold this hook can apply on Node. Either add c8 and a \"coverage\" script (stacks/node-ts.md K4.2), or put the threshold in your runner's own config (vitest coverage.thresholds, jest coverageThreshold) where npm test enforces it, and remove the key."
        return
      fi
      # The coverage script runs the tests, so its failure is K4.1 and there is no second run.
      run npm run coverage --silent \
        || { fail "K4.1 — the test suite is failing (npm run coverage):"$'\n'"$(tail -25 "$OUT")"; return; }
      if ! run npx --no-install c8 check-coverage --lines "$min"; then
        if bootstrap; then defer "K4.2 — line coverage is below the floor of ${min}%."
        else fail "K4.2 — line coverage is below the floor of ${min}%:"$'\n'"$(tail -10 "$OUT")"; fi
      fi
      ;;
    python)
      if bootstrap; then
        # pytest exits 5 when it collects no test: no tests yet. The floor is only reported.
        run pipenv run pytest ${min:+--cov}; local code=$?
        if [ "$code" = 5 ]; then defer "K4.1 — no tests yet."
        elif [ "$code" != 0 ]; then fail "K4.1 — the test suite is failing:"$'\n'"$(tail -25 "$OUT")"
        elif [ -n "$min" ]; then run pipenv run coverage report --fail-under="$min" || defer "K4.2 — coverage is below ${min}%."; fi
      elif [ -n "$min" ]; then
        run pipenv run pytest --cov --cov-fail-under="$min" \
          || fail "K4.1/K4.2 — tests failed or coverage is below ${min}%:"$'\n'"$(tail -25 "$OUT")"
      else
        run pipenv run pytest || fail "K4.1 — the test suite is failing:"$'\n'"$(tail -25 "$OUT")"
      fi
      ;;
    terraform)
      run terraform validate || fail "K4.1 — terraform validate failed."
      ;;
  esac
}

# ---- tier: rules (context injection) ---------------------------------------
# The banner states what this script actually does in THIS repo. It used to announce a
# coverage floor and a blocking push gate unconditionally, in repos where neither existed —
# see tier_full. Anything claimed here has to be something the tier above really runs.
tier_rules() {
  [ "$STACK" = none ] && exit 0
  local min cov enf
  min="$(cfg '.coverage')"
  case "$STACK" in
    flutter)
      cov="K4 real unit tests. Coverage is deliberately NOT gated on Flutter (stacks/flutter.md K4.2): flutter test --coverage omits every library no test imports, so no floor is set and none is enforced — a \"coverage\" key in .kheona.json is a finding, not a gate." ;;
    node)
      if [ -n "$min" ]; then
        cov="K4 real unit tests, line-coverage floor ${min}% — enforced on git push by c8 check-coverage over this repo's own \"coverage\" script (ratchet it up, never drop it)."
      else
        cov="K4 real unit tests. No coverage floor is set here, so git push gates the suite only; set \"coverage\" in .kheona.json to today's measured line % to add one."
      fi ;;
    python)
      if [ -n "$min" ]; then
        cov="K4 real unit tests, coverage floor ${min}% — enforced on git push by pytest --cov-fail-under (ratchet it up, never drop it)."
      else
        cov="K4 real unit tests. No coverage floor is set here, so git push gates the suite only; set \"coverage\" in .kheona.json to today's measured figure to add one."
      fi ;;
    *)
      cov="K4 real unit tests. This stack has no line-coverage measurement, so no floor is claimed or enforced." ;;
  esac
  bootstrap && cov="K4 bootstrap phase (.kheona.json): the tests that exist run on git push and none yet is accepted; the coverage floor is reported, not enforced; mutation testing is off. Set \"phase\": \"established\" (floor = today's measured figure) before the first production release: CI refuses it otherwise."
  if blocking; then
    enf="Enforced, not advisory: a PostToolUse hook flags K3.3/K5.2 violations per file, and hooks DENY git commit on a dirty lint/format/typecheck and git push on a failing suite"
    [ -n "$min" ] && [ "$STACK" != flutter ] && enf="$enf or coverage below the floor"
    enf="$enf."
  else
    enf="Advisory in this repo (\"blocking\" is not true): the same checks run — per-file K3.3/K5.2 on Write/Edit, lint/format/typecheck before git commit, the test suite before git push — and their findings are reported, but nothing is denied."
  fi
  jq -nc --arg s "$STACK" --arg c "$cov" --arg e "$enf" '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: (
        "Kheona standard is in force in this repo (stack: \($s)). The full checklist is the `kheona` skill; the short form:\n"
        + "K1 toolchain pinned and derived, lockfile committed. K2 CI is a required gate, no publish from a PR, everything pinned and time-bounded.\n"
        + "K3 lint/format/typecheck clean. A UI repo has a design system owning colour/typography/spacing/radius/shadow/motion and the shared components; build every screen from it, and when something is genuinely new add it TO the system and register it rather than styling it in the feature folder. Those rules and the layering rules are expressed as commands. "
        + $c + " K5 no secrets in the tree or in logs. K6 no stale PRs/issues. K7 CLAUDE.md current, UNVERIFIED marked. K8 identity consistent, rollback defined.\n"
        + $e + "\n"
        + "Nothing here is settled by reading documentation — every item is settled by running its command."
      )
    }
  }'
  exit 0
}

case "$TIER" in
  fast)  enabled fast || exit 0; tier_fast ;;
  gate)  enabled gate || exit 0; tier_gate ;;
  full)
    # An absent "coverage" key means no threshold — it does not mean no tests. Gating the
    # whole tier on that key is what made `git push` run lint and nothing else everywhere.
    if enabled full; then
      tier_full
    elif enabled gate; then
      tier_gate            # full explicitly disabled: fall back to the commit-time gate
    fi
    ;;
  rules) tier_rules ;;
  *) echo "usage: enforce.sh {fast <file>|gate|full|rules}" >&2; exit 64 ;;
esac

if [ -z "$FAILS" ]; then
  [ -n "$NOTES" ] && jq -nc --arg m "Kheona standard — K4 items deferred in the bootstrap phase:"$'\n'"$NOTES" '{systemMessage:$m}'
  exit 0
fi
[ -z "$NOTES" ] || FAILS="$FAILS"$'\n'"$NOTES"

MSG="Kheona standard — the following did not pass:"$'\n'"$FAILS"
if [ "$TIER" = fast ]; then
  jq -nc --arg m "$MSG" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
  exit 0
fi
if blocking; then
  jq -nc --arg m "$MSG" '{
    hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$m},
    systemMessage:"Kheona gate blocked this — see the reason above."
  }'
else
  # Advisory: surface the findings, let the command through.
  printf '%s\n(advisory — not blocked. Set {"blocking": true} in .kheona.json to enforce.)\n' "$MSG"
  jq -nc --arg m "$MSG" '{systemMessage:($m + "\n(advisory — not blocked)")}'
fi
exit 0
