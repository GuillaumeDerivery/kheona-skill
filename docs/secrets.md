<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# Variables and secrets

Every value comes from the calling repository. `.github/callers.json` lists what each workflow takes.

| Name | Kind | Needed by | What |
|---|---|---|---|
| `KSKILL_TOKEN_BROKER_URL` | variable | all | The token broker's address |
| `KSKILL_BOT` | variable | PR, Claude, Renovate | The App's bot login, `example-app[bot]` |
| `KSKILL_LIB_REPO` | variable | a repository with a private library submodule | `owner/library` |
| `CLAUDE_CODE_OAUTH_TOKEN` | secret | Claude review, `@claude`, triage | Optional: without it there is no review |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | secrets | deploy | Only without `awsRoleArn` |
| `SLACK_WEBHOOK_URL` | secret | deploy | Optional |
| `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT`, `SENTRY_REGION_URL` | secret, variables | Sentry triage, Flutter delivery | Optional |
| `ASC_*`, `IOS_DIST_*`, `ANDROID_KEYSTORE_BASE64`, `CM_*`, `PLAY_STORE_JSON_KEY_BASE64` | secrets | Flutter delivery | Store credentials |

A caller grants `id-token: write`: the broker and AWS both use the job's OIDC identity.
