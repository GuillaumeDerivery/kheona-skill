# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# shellcheck shell=bash
# Reads `.kheona.json` for kskill-ci-node.yml (`ci`) and the inbox's mutation job (`mutation`), validates it, and
# writes the values as step outputs. Every key is optional; a missing key is its documented default. A key of the
# wrong type, an unknown key, or a check pointed at an npm script package.json does not have, fails here, naming
# the key, so a typo never silently turns a check off. Never reads a secret.
#
# Usage, from the repository root: bash .github/scripts/kskill-node-config.sh ci|mutation
# Inputs from the environment (ci only): EVENT_NAME (github.event_name), CALLED ("true" under workflow_call, unused),
# PHASE (kskill-phase.sh: in "bootstrap" a missing test or coverage:check script means no tests yet, not a failure).
# Keys: see the header of kskill-ci-node.yml (`workflows.ci`) and kskill-inbox.yml's mutation job (`workflows.mutation`).
set -euo pipefail

mode="${1:?usage: kskill-node-config.sh ci|mutation}"
out="${GITHUB_OUTPUT:-/dev/stdout}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

fail() { echo "::error::$*" >&2; exit 1; }
emit() { printf '%s=%s\n' "$1" "$2" >> "$out"; }

[ -f package.json ] || fail "No package.json at the repository root: the Node workflows need one."
if [ -f .kheona.json ]; then
  jq -e 'type == "object"' .kheona.json > /dev/null 2>&1 || fail ".kheona.json is not a JSON object."
  wf="$(jq -c '.workflows // {}' .kheona.json)"
else
  wf='{}'
fi
[ "$(jq -r 'type' <<< "$wf")" = object ] || fail ".kheona.json: workflows must be an object."
ci="$(jq -c '.ci // {}' <<< "$wf")"
mu="$(jq -c '.mutation // {}' <<< "$wf")"
[ "$(jq -r 'type' <<< "$ci")" = object ] || fail ".kheona.json: workflows.ci must be an object."
[ "$(jq -r 'type' <<< "$mu")" = object ] || fail ".kheona.json: workflows.mutation must be an object."

# get <json> <key> <type> <default> <label>: the value (compact JSON for objects), or the default when absent.
get() {
  local t
  t="$(jq -r --arg k "$2" '.[$k] | type' <<< "$1")"
  if [ "$t" = null ]; then printf '%s' "$4"; return; fi
  [ "$t" = "$3" ] || fail ".kheona.json: $5.$2 must be a $3, found a $t."
  jq -cr --arg k "$2" '.[$k]' <<< "$1"
}
# unknown <json> <label> <allowed...>: fails on any key not in the allowed list.
unknown() {
  local json="$1" label="$2" bad; shift 2
  bad="$(jq -r --args '[keys[] | select(IN($ARGS.positional[]) | not)] | join(", ")' "$@" <<< "$json")"
  [ -z "$bad" ] || fail ".kheona.json: unknown key(s) in $label: $bad. Allowed: $*."
}
int_in() { # int_in <value> <min> <max> <label>
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ] || fail ".kheona.json: $4 must be an integer from $2 to $3, found $1."
}
rel_path() { # rel_path <value> <label>: a relative path inside the repository
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ && "$1" != /* && "$1" != *..* ]] || fail ".kheona.json: $2 must be a relative path inside the repository, found '$1'."
}
has_script() { jq -e --arg s "$1" '(.scripts // {})[$s] | type == "string"' package.json > /dev/null; }

# Shared by both modes (read from workflows.ci): the lib submodule, extra environment, MongoDB download.
lib_path="$(get "$ci" libPath string submodules/lib workflows.ci)"
rel_path "$lib_path" workflows.ci.libPath
submodules=false
has_lib=false
if [ -f .gitmodules ]; then
  submodules=true
  if git config --file .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}' | grep -qxF "$lib_path"; then has_lib=true; fi
fi
emit submodules "$submodules"
emit has_lib "$has_lib"
emit lib_path "$lib_path"

env_json="$(get "$ci" env object '{}' workflows.ci)"
bad_env="$(jq -r 'to_entries[] | select((.key | test("^[A-Z_][A-Z0-9_]*$") | not)
  or (.key | test("^(GITHUB_|RUNNER_|ACTIONS_)"))
  or (.key == "PATH") or (.key == "HOME")
  or (.value | type != "string") or (.value | test("[\r\n]"))) | .key' <<< "$env_json")"
[ -z "$bad_env" ] || fail ".kheona.json: workflows.ci.env entries must be UPPER_CASE names (not GITHUB_*, RUNNER_*, ACTIONS_*, PATH, HOME) with one-line string values; offending: $(echo "$bad_env" | tr '\n' ' ')"
emit env_json "$env_json"
emit mongo "$(get "$ci" mongoDownload boolean true workflows.ci)"

# Node version: from the repository, never from a default.
if [ -f .nvmrc ]; then
  node_file=.nvmrc
elif [ -f .node-version ]; then
  node_file=.node-version
else
  node_file=package.json
  engines="$(jq -r '.engines.node // empty' package.json)"
  [ -n "$engines" ] || fail "No .nvmrc, no .node-version and no engines.node in package.json: the Node version must be stated in the repository."
  [[ "$engines" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || echo "::warning::Node version taken from engines.node '$engines', a range rather than one exact version. Add an .nvmrc with the exact version."
fi
emit node_version_file "$node_file"

if [ "$mode" = ci ]; then
  unknown "$ci" workflows.ci skip scripts env mongoDownload libPath runOnPush timeoutMinutes coveragePath
  checks=(build typecheck lint format importGraph deadCode test coverageCheck coverageReport docker libVersions)
  script_checks=(build typecheck lint format importGraph deadCode test coverageCheck)
  default_script() {
    case "$1" in
      build) echo build ;; typecheck) echo typecheck ;; lint) echo lint ;; format) echo format:check ;;
      importGraph) echo depcruise ;; deadCode) echo knip ;; test) echo coverage ;; coverageCheck) echo coverage:check ;;
      *) echo "" ;;
    esac
  }

  skip="$(get "$ci" skip object '{}' workflows.ci)"
  # envFiles, gitCrypt and mongoUri are read by the repository check (checks 7, 8 and 9, ), secretScan by the secret
  # scan (actions/kskill-repo-check), not run here.
  unknown "$skip" workflows.ci.skip "${checks[@]}" envFiles gitCrypt mongoUri secretScan
  bad="$(jq -r 'to_entries[] | select((.value | type != "string") or (.value | test("^\\s*$"))) | .key' <<< "$skip")"
  [ -z "$bad" ] || fail ".kheona.json: each workflows.ci.skip entry is the reason the check is off, a non-empty string; offending: $bad"

  scripts="$(get "$ci" scripts object '{}' workflows.ci)"
  unknown "$scripts" workflows.ci.scripts "${script_checks[@]}"
  script_for() { # the npm script a check runs: the override, else the default; empty for a non-script check
    local v
    v="$(jq -r --arg k "$1" '.[$k] // empty' <<< "$scripts")"
    if [ -n "$v" ]; then
      [[ "$v" =~ ^[A-Za-z0-9:._-]+$ ]] || fail ".kheona.json: workflows.ci.scripts.$1 must be an npm script name, found '$v'."
      echo "$v"
    else
      default_script "$1"
    fi
  }

  {
    echo '## CI configuration'
    echo
    echo '| Check | Runs | Command or reason |'
    echo '|---|---|---|'
  } >> "$summary"
  no_tests=false
  for c in "${checks[@]}"; do
    reason="$(jq -r --arg k "$c" '.[$k] // empty' <<< "$skip")"
    sc="$(script_for "$c")"
    run=true
    detail=""
    if [ -n "$reason" ]; then
      run=false; detail="skipped in .kheona.json: $reason"
    elif [ "${PHASE:-established}" = bootstrap ] && [ "$c" = coverageReport ] && [ "$no_tests" = true ]; then
      run=false; detail="bootstrap phase: no tests yet"
    elif [ "${PHASE:-established}" = bootstrap ] && { [ "$c" = test ] || [ "$c" = coverageCheck ]; } && ! has_script "$sc"; then
      run=false; detail="bootstrap phase: no \"$sc\" script yet"
      if [ "$c" = test ]; then no_tests=true; fi
    elif [ "$c" = docker ] && [ ! -f Dockerfile ]; then
      run=false; detail="no Dockerfile"
    elif [ "$c" = libVersions ] && [ "$has_lib" != true ]; then
      run=false; detail="no $lib_path submodule"
    elif [ -n "$sc" ]; then
      has_script "$sc" || fail "package.json has no \"$sc\" script, which the CI check '$c' runs. Add it, point workflows.ci.scripts.$c at the script that does it, or turn the check off with workflows.ci.skip.$c set to the reason."
      detail="npm run $sc"
    fi
    if [ "$c" = lint ] && [ "$run" = true ]; then
      # the script CI calls is the strict one. Read its text, not that a linter is installed.
      jq -r --arg s "$sc" '.scripts[$s]' package.json | grep -qE -- '--max-warnings[= ]0([^0-9]|$)' \
        || fail "The \"$sc\" script does not pass --max-warnings=0, so a warning would not fail CI."
    fi
    emit "run_$c" "$run"
    [ -z "$sc" ] || emit "script_$c" "$sc"
    echo "| \`$c\` | $run | ${detail:-yes} |" >> "$summary"
  done

  coverage_path="$(get "$ci" coveragePath string coverage/ workflows.ci)"
  rel_path "$coverage_path" workflows.ci.coveragePath
  emit coverage_path "$coverage_path"

  timeout="$(get "$ci" timeoutMinutes number 30 workflows.ci)"
  int_in "$timeout" 5 360 workflows.ci.timeoutMinutes
  emit timeout "$timeout"

  # workflows.ci.runOnPush is retired, accepted and ignored: every push run of this gate is a called one (Main, the
  # production deploy), and skipping it there would deploy untested.
  get "$ci" runOnPush boolean true workflows.ci > /dev/null
  emit run true

elif [ "$mode" = mutation ]; then
  unknown "$mu" workflows.mutation script concurrency incremental testsDir reportPath timeoutMinutes
  m_script="$(get "$mu" script string mutation workflows.mutation)"
  [[ "$m_script" =~ ^[A-Za-z0-9:._-]+$ ]] || fail ".kheona.json: workflows.mutation.script must be an npm script name."
  has_script "$m_script" || fail "package.json has no \"$m_script\" script (\"stryker run\"). Add it, or set workflows.mutation.script."
  emit script "$m_script"

  conc="$(get "$mu" concurrency number '' workflows.mutation)"
  [ -z "$conc" ] || int_in "$conc" 1 64 workflows.mutation.concurrency
  emit concurrency "$conc"

  timeout="$(get "$mu" timeoutMinutes number 60 workflows.mutation)"
  int_in "$timeout" 5 360 workflows.mutation.timeoutMinutes
  emit timeout "$timeout"

  report_path="$(get "$mu" reportPath string reports/mutation/ workflows.mutation)"
  rel_path "$report_path" workflows.mutation.reportPath
  emit report_path "$report_path"

  cfg=""
  for f in stryker.config.json stryker.conf.json stryker.config.mjs stryker.config.js stryker.config.cjs stryker.conf.js; do
    if [ -f "$f" ]; then cfg="$f"; break; fi
  done
  [ -n "$cfg" ] || fail "No Stryker config (stryker.config.json, .mjs, .js...) at the repository root."
  # The scope is the repository's: Stryker reads `mutate` from its own config, the shared options never widen it.
  if [[ "$cfg" == *.json ]]; then
    jq -e '(.mutate | type == "array") and (.mutate | length > 0)' "$cfg" > /dev/null \
      || fail "$cfg has no \"mutate\" list: scope it to the targets, or Stryker mutates every file and the run does not fit its timeout."
    scope="$(jq -r '.mutate | join(", ")' "$cfg")"
    incremental_file="$(jq -r '.incrementalFile // "reports/stryker-incremental.json"' "$cfg")"
  else
    grep -qE '\bmutate\b' "$cfg" || fail "$cfg sets no \"mutate\": scope it to the targets."
    scope="see $cfg"
    incremental_file=reports/stryker-incremental.json
  fi
  rel_path "$incremental_file" "$cfg incrementalFile"
  emit stryker_config "$cfg"
  emit incremental_file "$incremental_file"

  incremental="$(get "$mu" incremental boolean false workflows.mutation)"
  tests_dir="$(get "$mu" testsDir string tests workflows.mutation)"
  rel_path "$tests_dir" workflows.mutation.testsDir
  emit incremental "$incremental"
  # The previous result is reused only while the tests, the dependencies (lockfile and lib pointer) and the
  # Stryker config (its own file and the shared options it spreads) are byte-identical: with the `command` runner
  # Stryker cannot tell that a test changed.
  key="$(git ls-files -s -- "$tests_dir" package-lock.json "$cfg" .github/config/kskill-stryker.mjs "$lib_path" | sha256sum | cut -c1-40)"
  emit incremental_key "$key"

  {
    echo '## Mutation testing configuration'
    echo
    echo "- Stryker config: \`$cfg\`, mutate: $scope"
    echo "- Command: \`npm run $m_script${conc:+ -- --concurrency $conc}\`"
    echo "- Incremental result restored: $incremental"
  } >> "$summary"
else
  fail "usage: kskill-node-config.sh ci|mutation"
fi
