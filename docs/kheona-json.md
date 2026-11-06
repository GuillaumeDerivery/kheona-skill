<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# `.kheona.json`

Each shared workflow's header comment lists the keys it reads, their types and defaults. The main ones:

| Key | Default | Meaning |
|---|---|---|
| `role` | `project` | `project`, `library`, `template` or `infra` |
| `phase` | `established` | `bootstrap` holds shipping and reports the coverage floor without enforcing it |
| `workflows.automerge.enabled` | `true` | `false` where a merge to the default branch deploys production |
| `workflows.ci.skip.<check>` | none | Turns a check off; the value is the reason |
| `workflows.cd.<env>` | none | `ecrRepository`, `region`, `cluster`, `namespace`, `deployments`, `cronjobs`, `buildArgs`, `awsRoleArn` |
| `workflows.local.<file>` | none | A workflow of the repository's own; the value is the reason |
| `workflows.library.package` | none | The npm name of a library submodule, for the `.env` rule of its services |
| `workflows.releasePlease` | none | How a library's release PR merges |
