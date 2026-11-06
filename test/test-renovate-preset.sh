#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Offline test of renovate/default.json's Pipfile manager: the custom regex manager that moves Pipfile's
# [requires] python_version with the Python runtime group (Renovate's pipenv manager reads it, never updates it).
# The preset's own patterns, applied by Node as Renovate applies them (JavaScript regular expressions), to fixtures.
# Checked end to end once with Renovate 44.149.0 (--platform=local --dry-run=lookup on a repository's Dockerfile,
# .python-version and Pipfile): Pipfile "3.14" -> "3.15" on renovate/python-runtime, with the image's 3.14.9 -> 3.15.1.
set -uo pipefail
export KSKILL_REPO=owner/kheona-skill KSKILL_BOT='example-app[bot]'
HERE=$(cd "$(dirname "$0")/.." && pwd)
pass=0; failn=0
check() { # check <name> <actual> <expected>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"
  else failn=$((failn+1)); echo "FAIL $1 (expected \"$3\", got \"$2\")"; fi
}
# match <file name> <content>: the currentValue the manager extracts, "-" when the file is not its, "" when no match.
match() {
  PRESET="$HERE/renovate/default.json" NAME="$1" CONTENT="$2" node -e '
    const p = require(process.env.PRESET);
    const m = p.customManagers.find(c => c.customType === "regex" && c.managerFilePatterns.some(f => /Pipfile/.test(f)));
    const re = s => new RegExp(s.slice(1, s.lastIndexOf("/")), s.slice(s.lastIndexOf("/") + 1));
    if (!m.managerFilePatterns.some(f => re(f).test(process.env.NAME))) { console.log("-"); process.exit(0); }
    const v = m.matchStrings.map(s => new RegExp(s, "g")).flatMap(r => [...process.env.CONTENT.matchAll(r)]).map(x => x.groups.currentValue);
    console.log(v.join(","));
    if (m.depNameTemplate !== "python" || m.datasourceTemplate !== "docker" || m.versioningTemplate !== "docker") process.exit(3);'
}

pipfile='[[source]]
url = "https://pypi.org/simple"

[packages]
flask = "==3.1.2"

[dev-packages]
pytest = "*"

[requires]
python_version = "3.14"
'
check "Pipfile: [requires] python_version is extracted"       "$(match Pipfile "$pipfile")" 3.14
check "a Pipfile in a subdirectory too"                        "$(match api/Pipfile "$pipfile")" 3.14
check "Pipfile.lock is not this manager's file"                "$(match Pipfile.lock "$pipfile")" -
check "a Pipfile without [requires]: nothing"                  "$(match Pipfile '[packages]
flask = "*"
')" ""
check "python_version outside [requires]: not taken"           "$(match Pipfile '[packages]
python_version = "3.14"

[dev-packages]
')" ""
check "python_full_version is not python_version"              "$(match Pipfile '[requires]
python_full_version = "3.14.9"
')" ""
check "spacing around = is free"                               "$(match Pipfile '[requires]
python_version="3.13"
')" 3.13
check "the depName, datasource and versioning are the image's" "$(match Pipfile "$pipfile" >/dev/null; echo $?)" 0

# The Python runtime group takes depName python whatever the manager, and a minor is a draft for a person.
group=$(jq -r '[.packageRules[] | select(.matchDepNames == ["python"] and .groupSlug == "python-runtime")] | length' "$HERE/renovate/default.json")
check "the Python runtime group matches depName python"        "$group" 1
check "a Python minor stays a draft"                           "$(jq -r '[.packageRules[] | select(.matchDepNames == ["python"] and (.matchUpdateTypes // [] | index("minor")))][0].draftPR' "$HERE/renovate/default.json")" true

# security PRs from OSV, Dependabot being off; checked end to end with Renovate (--platform=local --dry-run=lookup
# on a Node and a Python repository, 2026-10-26: "fetchVulnerabilities() - osvVulnerabilityAlerts=true").
P="$HERE/renovate/default.json"
check "OSV vulnerability alerts on"                            "$(jq -r .osvVulnerabilityAlerts "$P")" true
check "a security PR at any time"                              "$(jq -c .vulnerabilityAlerts.schedule "$P")" '["at any time"]'
check "labelled security, added to its update type's labels"   "$(jq -c '[.vulnerabilityAlerts.addLabels, (.vulnerabilityAlerts | has("labels"))]' "$P")" '[["security"],false]'
check "its merge policy is its update type's (no automerge, draftPR of its own)" \
  "$(jq -c '.vulnerabilityAlerts | [has("automerge"), has("draftPR")]' "$P")" '[false,false]'

# Renovate's OSV lookup skips a Pipfile range (~=) and reads nothing from Pipfile.lock, so pipenv pins. Checked end to
# end with Renovate 44.149.0 (--platform=local --dry-run=full, 2026-10-26): a ~= Pipfile gets one pin PR per entry
# at its locked version in the minor/patch group (renovate/all-minor-patch since 2026-10-26), and a pinned gunicorn==21.2.0 is reported
# ("Vulnerability GHSA-hc5x-x2vx-497g affects gunicorn 21.2.0") where ~=4.5.0 is "Skipping vulnerability lookup".
check "pipenv: rangeStrategy pin"                              "$(jq -c '[.packageRules[] | select(.matchManagers == ["pipenv"]) | .rangeStrategy]' "$P")" '["pin"]'
check "a pin is merged like a minor"                           "$(jq -r '[.packageRules[] | select(.groupSlug == "all-minor-patch")][0].matchUpdateTypes | index("pin") != null' "$P")" true

# cadence (decided 2026-10-26): one weekly PR per repository for every non-major update, the lock file on its own
# day, the majors in one draft, security at once. Checked end to end with Renovate 44.149.0 (--platform=local
# --dry-run=full) on a stale Node + Docker + Actions + Pipfile fixture: 8 branches, renovate/all-minor-patch (npm, Docker,
# Actions, .nvmrc, the Python patch), renovate/major-all, renovate/python-runtime, the lock file, one per vulnerability.
check "Monday, Paris time (the doctor dispatches from about 07:00 Paris)"  "$(jq -c '[.timezone, .schedule]' "$P")" '["Europe/Paris",["* * * * 1"]]'
check "an open PR is touched only in its window"               "$(jq -r .updateNotScheduled "$P")" false
check "lock file maintenance on Thursday"                      "$(jq -c .lockFileMaintenance.schedule "$P")" '["* * * * 4"]'
check "one group for every non-major update"                   "$(jq -c '[.packageRules[] | select(.groupSlug == "all-minor-patch") | .matchUpdateTypes]' "$P")" '[["minor","patch","pin","pinDigest","digest"]]'
check "no group per ecosystem left"                            "$(jq -c '[.packageRules[] | select(.matchCategories) ] | length' "$P")" 0
check "one draft for every major"                              "$(jq -c '[.packageRules[] | select(.matchUpdateTypes == ["major"] and .groupSlug == "all") | .draftPR]' "$P")" '[true]'
check "a 0.x minor goes to the majors' draft"                  "$(jq -r '[.packageRules[] | select(.matchCurrentVersion)][0] | [.groupSlug, .draftPR] | join(" ")' "$P")" "major-all true"
check "the Python patch joins the weekly branch"               "$(jq -r '[.packageRules[] | select(.matchDepNames == ["python"] and .matchUpdateTypes == ["patch"])][0].group.branchTopic' "$P")" all-minor-patch
check "no-automerge keeps the cadence (no schedule of its own)" "$(jq -c '[has("schedule"), has("updateNotScheduled"), (.lockFileMaintenance | has("schedule"))]' "$HERE/renovate/no-automerge.json")" '[false,false,false]'

# role: infra (renovate/infra.json). Checked end to end with Renovate 44.149.0 (--platform=local --dry-run=lookup, the presets
# merged as global configuration, 2026-10-27) on a copy of an infra repository's manifests and Terraform: vaultwarden/server
# 1.37.2 -> 1.37.4 on renovate/all-minor-patch, cert-manager v1.19.1 -> v1.21.3 on renovate/cert-manager-manifest, every
# SHA-tagged or latest ECR image and every image inside a release manifest disabled, ingress-nginx (archived) no update.
I="$HERE/renovate/infra.json"
# infra <manager index> <file name> <content>: the currentValues the infra preset's regex manager extracts ("-": not its file).
infra() {
  PRESET="$I" IDX="$1" NAME="$2" CONTENT="$3" node -e '
    const m = require(process.env.PRESET).customManagers[Number(process.env.IDX)];
    const re = s => new RegExp(s.slice(1, s.lastIndexOf("/")), s.slice(s.lastIndexOf("/") + 1));
    if (!m.managerFilePatterns.some(f => re(f).test(process.env.NAME))) { console.log("-"); process.exit(0); }
    console.log(m.matchStrings.map(s => new RegExp(s, "g")).flatMap(r => [...process.env.CONTENT.matchAll(r)]).map(x => x.groups.currentValue).join(","));'
}
check "infra: extends no-automerge (applying is manual)"       "$(jq -c .extends "$I")" '["github>GuillaumeDerivery/kheona-skill//renovate/no-automerge"]'
check "infra: the kubernetes manager reads eks/ only"          "$(PRESET="$I" node -e 'const p=require(process.env.PRESET);const re=s=>new RegExp(s.slice(1,s.lastIndexOf("/")));console.log(["eks/vault/deployments/v.yaml","eks/gs/x.yml","backup/eks/link/a.yml","eks.yaml"].map(f=>p.kubernetes.managerFilePatterns.some(x=>re(x).test(f))).join(","))')" 'true,true,false,false'
check "infra: cert-manager's version labels, quoted"           "$(infra 0 eks/cert-manager/cert-manager.yaml $'    app.kubernetes.io/version: "v1.19.1"\n    app.kubernetes.io/version: "v1.19.1"')" 'v1.19.1,v1.19.1'
check "infra: ... only in its directory"                       "$(infra 0 eks/gs/x.yaml 'app.kubernetes.io/version: "v1.19.1"')" -
check "infra: ingress-nginx's version labels, unquoted"        "$(infra 1 eks/ingress-nginx/deploy.yaml '    app.kubernetes.io/version: 1.15.1')" '1.15.1'
check "infra: ingress-nginx follows controller-v* releases"    "$(jq -r '.customManagers[1] | [.depNameTemplate, .datasourceTemplate, .extractVersionTemplate] | join(" ")' "$I")" 'kubernetes/ingress-nginx github-releases ^controller-v(?<version>\d+\.\d+\.\d+)$'
check "infra: a SHA or latest tag is never updated"            "$(PRESET="$I" node -e 'const r=require(process.env.PRESET).packageRules[0];const re=new RegExp(r.matchCurrentValue.slice(1,-1));console.log(r.enabled,["81ae6b86604daf5cd81910bf66efb90563fa2219","latest","1.37.2","v1.6.9","eb6b2a2"].map(v=>re.test(v)).join(","))')" 'false true,true,false,false,true'
check "infra: the owner's ECR images are never updated"        "$(PRESET="$I" node -e 'const r=require(process.env.PRESET).packageRules[1];const re=new RegExp(r.matchPackageNames[0].slice(1,-1));console.log(r.enabled,["111122223333.dkr.ecr.eu-west-1.amazonaws.com/backend","docker.io/example/server"].map(v=>re.test(v)).join(","))')" 'false true,false'
check "infra: a release manifest's images never move alone"    "$(jq -c '.packageRules[2] | [.matchFileNames, .enabled]' "$I")" '[["eks/cert-manager/**","eks/ingress-nginx/**"],false]'
check "infra: each release manifest a draft of its own"        "$(jq -c '[.packageRules[3,4] | [.groupSlug, .draftPR, .automerge]]' "$I")" '[["cert-manager-manifest",true,false],["ingress-nginx-manifest",true,false]]'

echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
