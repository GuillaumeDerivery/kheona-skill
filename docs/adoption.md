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

2. **Releases:** `release-please-config.json` and `.release-please-manifest.json` at the root, the manifest seeded at the current version (`{".": "1.4.0"}`), and squash merges only (the settings script sets it). See the README's "Releases and deploys".
3. **Caller files**, one per event. The stack is read from the repository:

   ```bash
   node scripts/kskill-callers.mjs write --repo . --self owner/kheona-skill --sha <40-hex-commit> --version v2.0.0
   ```

4. **`renovate.json`:** `{"extends": ["github>owner/kheona-skill//renovate/default#v2.0.0"]}`: the generator pins the preset at the callers' version.
5. **Variables and secrets:** see [secrets.md](secrets.md) and the [README](../README.md#secrets). Callers pass secrets by name; `secrets: inherit` does not cross owners. The App key is never one of them.
6. **Topic:** add `kheona-skill` or `kskill`. A library's consumers add the topic the library's `.kheona.json` names.
7. **Prove it:** open a test PR. It must pass CI and review, and merge.

`node scripts/kskill-callers.mjs check --repo .` says when a caller is missing or differs from what its version expects. Renovate opens one PR per release of this repository, moving every caller and the preset pin; when a version changes a caller's content, CI says so and the setup command rewrites it on that branch.
