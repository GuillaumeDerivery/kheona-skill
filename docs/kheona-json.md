<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# `.kheona.json`

Each shared workflow's header comment lists the keys it reads, their types and defaults. The main ones:

| Key | Default | Meaning |
|---|---|---|
| `role` | `project` | `project`, `library`, `template` or `infra` |
| `phase` | `established` | `bootstrap` refuses the first release and reports the coverage floor without enforcing it |
| `workflows.automerge.enabled` | `true` | `false` stops merging automation PRs |
| `workflows.ci.skip.<check>` | none | Turns a check off; the value is the reason |
| `workflows.cd.target` | `eks` | `custom`: the repository's own workflow deploys, after the release check and the gate |
| `workflows.cd.custom.workflow` | `deploy.yml` | That workflow (`on: workflow_call`, inputs `environment` and `version`) |
| `workflows.cd.<env>` | none | `staging` (from `main`) or `prod` (from a version tag): `ecrRepository`, `region`, `cluster`, `namespace`, `deployments`, `cronjobs`, `buildArgs`, `awsRoleArn`; `false` = none |
| `workflows.local.<file>` | none | A workflow of the repository's own; the value is the reason |
| `workflows.library.package` | none | The npm name of a library submodule, for the `.env` rule of its services |
| `workflows.releasePlease.merge` | `person`; `gate` in a library | Who merges the release PR; `gate` and `daily` are for a library only |
