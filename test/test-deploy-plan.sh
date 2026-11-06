#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline tests for kskill-deploy.yml's plan step (.kheona.json workflows.cd -> the deploy job's inputs): the one
# platform and its native runner (never emulated), and each environment's build arguments. The step's script is read
# from the template itself, so the tests run what the repositories run.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
check() { # check <name> <output> <grep -E pattern>
  if grep -qE -- "$3" <<<"$2"; then pass=$((pass+1)); echo "ok   $1"
  else failn=$((failn+1)); echo "FAIL $1 (pattern $3)"; printf '     %s\n' "${2//$'\n'/$'\n'     }"; fi
}
ruby -ryaml -e 'w=YAML.load_file(ARGV[0]); File.write(ARGV[1], w["jobs"]["plan"]["steps"].find{|x| x["id"]=="read"}["run"])' \
  "$HERE/.github/workflows/kskill-deploy.yml" "$T/plan.sh"
# plan <name> <.kheona.json> [branch]: "rc=N" then the outputs and the annotations.
plan() {
  local d="$T/$1"; mkdir -p "$d"; printf '%s' "$2" > "$d/.kheona.json"
  (cd "$d" && GITHUB_OUTPUT="$d/out" EVENT=${EVENT:-push} GITHUB_REF="refs/heads/${3:-main}" GITHUB_REPOSITORY=o/r bash "$T/plan.sh" > "$d/log" 2>&1; echo "rc=$?")
  cat "$d/out" 2>/dev/null; grep -E '::(error|notice)::' "$d/log"
}
E='"ecrRepository":"x","region":"eu-west-3","cluster":"c","namespace":"n","deployments":["d"]'
P='"ecrRepository":"y","region":"eu-west-3","cluster":"c","namespace":"n","deployments":["d"]'

out=$(plan default "{\"workflows\":{\"cd\":{\"staging\":{$E},\"prod\":{$E}}}}")
check "default: linux/arm64 on the arm64 runner"          "$out" '^platform=linux/arm64$'
check "... ubuntu-24.04-arm"                               "$out" '^runner=ubuntu-24.04-arm$'
check "... no build arguments"                             "$out" '^build-args=\{\}$'
out=$(plan amd64 "{\"workflows\":{\"cd\":{\"platform\":\"linux/amd64\",\"staging\":{$E},\"prod\":{$E}}}}")
check "linux/amd64: the amd64 runner"                      "$out" '^runner=ubuntu-24.04$'
out=$(plan several "{\"workflows\":{\"cd\":{\"platforms\":\"linux/amd64,linux/arm64\",\"staging\":{$E},\"prod\":{$E}}}}")
check "several platforms: refused, nothing is emulated"    "$out" '^rc=1$'
check "... saying which key to set"                        "$out" 'lists several platforms: build one, natively'
out=$(plan legacy "{\"workflows\":{\"cd\":{\"platforms\":\"linux/arm64\",\"staging\":{$E},\"prod\":{$E}}}}")
check "the older key with one platform still works"        "$out" '^runner=ubuntu-24.04-arm$'
check "... with a notice to rename it"                     "$out" 'rename it to workflows.cd.platform'
out=$(plan bogus "{\"workflows\":{\"cd\":{\"platform\":\"linux/riscv\",\"staging\":{$E},\"prod\":{$E}}}}")
check "an unknown platform: refused"                       "$out" "invalid \('linux/riscv'\)"
out=$(plan args "{\"workflows\":{\"cd\":{\"staging\":{$E,\"buildArgs\":{\"API_URL\":\"https://s\"}},\"prod\":{$P,\"buildArgs\":{\"API_URL\":\"https://p\"}}}}}")
check "buildArgs: this environment's, as JSON"             "$out" '^build-args=\{"API_URL":"https://s"\}$'
out=$(plan args-prod "{\"workflows\":{\"cd\":{\"staging\":{$E,\"buildArgs\":{\"API_URL\":\"https://s\"}},\"prod\":{$P,\"buildArgs\":{\"API_URL\":\"https://p\"}}}}}" prod)
check "... production gets its own"                        "$out" '^build-args=\{"API_URL":"https://p"\}$'
out=$(plan same-repo "{\"workflows\":{\"cd\":{\"staging\":{$E,\"buildArgs\":{\"API_URL\":\"https://s\"}},\"prod\":{$E,\"buildArgs\":{\"API_URL\":\"https://p\"}}}}}")
check "different images into one ecrRepository: refused"  "$out" 'same ecrRepository'
out=$(plan bad-name "{\"workflows\":{\"cd\":{\"staging\":{$E,\"buildArgs\":{\"bad-name\":\"v\"}},\"prod\":false}}}")
check "a build argument name that is not NAME: refused"    "$out" 'buildArgs must be an object of NAME'
check "the action builds natively only: no QEMU"           "$(grep -c "setup-qemu-action" "$HERE/.github/actions/kskill-deploy-eks/action.yml" "$HERE/.github/workflows/kskill-deploy.yml" | cut -d: -f2 | paste -sd+ - | bc)" '^0$'

out=$(EVENT=pull_request plan pr-refused "{\"workflows\":{\"cd\":{\"staging\":{$E}}}}")
check "a pull request: refused"                            "$out" 'only deploys as a dry run'
out=$(EVENT=pull_request DRY_RUN=true plan pr-dry "{\"workflows\":{\"cd\":{\"staging\":{$E}}}}")
check "a pull request as a dry run: staging"               "$out" '^environment=staging$'
ROLE=arn:aws:iam::111122223333:role/example
out=$(plan role "{\"workflows\":{\"cd\":{\"staging\":{$E,\"awsRoleArn\":\"$ROLE\"},\"prod\":{$E}}}}")
check "awsRoleArn: this environment's role"                "$out" "^aws-role-arn=$ROLE$"
out=$(plan role-prod "{\"workflows\":{\"cd\":{\"staging\":{$E,\"awsRoleArn\":\"$ROLE\"},\"prod\":{$E}}}}" prod)
check "... not the other environment's"                    "$out" '^aws-role-arn=$'

echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
