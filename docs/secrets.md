<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# Variables

Every value comes from the calling repository, set as an Actions variable. Secrets are in the [README](../README.md#secrets); `.github/callers.json` lists what each workflow takes.

| Name | Needed by | What |
|---|---|---|
| `KSKILL_TOKEN_BROKER_URL` | all | The token broker's address |
| `KSKILL_BOT` | PR, Claude, Renovate | The App's bot login, `example-app[bot]` |
| `KSKILL_LIB_REPO` | a repository with a private library submodule | `owner/library` |
| `KSKILL_AUTOMERGE` | PR | `false` stops merging automation PRs, release PRs excepted |
| `KSKILL_DIST_REBUILD` | PR | `true` rebuilds a committed output on the PR's branch |
| `KSKILL_CD_STAGING`, `KSKILL_CD_PROD` | Deploy | `false` turns that environment's deploy off |
| `KSKILL_RELEASE_PR` | Push to `main` | `false` stops opening the release PR |
| `BUILD_NUMBER_OVERRIDE` | Flutter delivery | Replaces the build number for one run |
| `SENTRY_ORG`, `SENTRY_PROJECT`, `SENTRY_REGION_URL` | Sentry triage | Which Sentry project to read |

A caller grants `id-token: write`: the broker and AWS both use the job's OIDC identity.
