<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# Adopting kheona-skill

1. **`.kheona.json`** at the root: at least `{"role": "project"}`. A service adds its deploy:

   ```json
   {
     "role": "project",
     "workflows": {
       "cd": {
         "platform": "linux/arm64",
         "staging": { "ecrRepository": "example-app", "region": "eu-west-1", "cluster": "example-cluster", "namespace": "staging", "deployments": ["example-app"], "awsRoleArn": "arn:aws:iam::111122223333:role/example-staging" }
       }
     }
   }
   ```

2. **Caller files**, one per event. The stack is read from the repository:

   ```bash
   node scripts/kskill-callers.mjs write --repo . --self owner/kheona-skill --sha <40-hex-commit> --version v1.0.0
   ```

3. **`renovate.json`:** `{"extends": ["github>owner/kheona-skill//renovate/default"]}`.
4. **Variables and secrets:** see [secrets.md](secrets.md). Callers pass secrets by name; `secrets: inherit` does not cross owners. The App key is never one of them.
5. **Topic:** add `kheona-skill` or `kskill`. A library's consumers add the topic the library's `.kheona.json` names.
6. **Prove it:** open a test PR. It must pass CI and review, and merge.

`node scripts/kskill-callers.mjs check --repo .` says when a caller is missing or differs from what its version expects. A Renovate bump regenerates the callers in the same PR.
