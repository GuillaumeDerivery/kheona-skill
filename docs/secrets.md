<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# Secrets and variables

Four places hold secrets, and only the broker holds the GitHub App key. Values are never printed and never reach a public log. A caller passes each secret by name: `secrets: inherit` does not cross owners. Variables are [below](#variables).

## On this repository

| Secret | Used by | What it does |
|---|---|---|
| `KSKILL_GUARD_TERMS` | `guard.yml` | The private list of forbidden names, one per line. The guard fails if a file, a commit or a PR's text holds one. A fork's PR never receives it. |
| `GITHUB_TOKEN` | automatic | GitHub's own token for each run. Nothing to set. |

## On the private runner repository

The runner repository calls `kskill-guard.yml` on a schedule: it reads each fork's PR here without running it and sets
its `rule-0` status, with the App's token from the broker (the runner is in the broker's `acrossOwners`).

| Secret | What it does |
|---|---|
| `KSKILL_GUARD_TERMS` | The same list, so a fork's PR is checked too. |

`main` requires `rule-0` (a commit status: the guard on this repository's own PRs, the runner on a fork's), `test`
and `zizmor`. A required check passes on a skipped job; a status nobody set stays pending, so a fork's PR waits for the
runner.

On your own machine, the same guard and list run before anything leaves it:
`bash scripts/kskill-guard-hook.sh install <list file>` in a clone adds git hooks (`pre-commit` on the files,
`commit-msg` on the message, `pre-push` on the commits). With `kskill-guard-hook.sh claude` as a Claude Code
`PreToolUse` hook on `Bash`, a `git` or `gh` command aimed at this repository is denied when its text, body file or
pushed commits hold a term.

## On each repository with the `kheona-skill` or `kskill` topic

Set only what the repository uses. A workflow that lacks a required secret fails with its name before any real work starts; an optional one only turns its feature off.

| Secret | Needed by | Required | What it does |
|---|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | PR, `@claude`, inbox | Optional | Signs Claude Code in, for the review of automation PRs, `@claude` and the fixes of the Sentry triage. Without it there is no review. |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Deploy | Only without `awsRoleArn` | A stored AWS key for ECR and EKS. Prefer `awsRoleArn` in `.kheona.json`: the job then uses its OIDC identity and neither secret exists. |
| `SLACK_WEBHOOK_URL` | Deploy | Optional | Announces each deploy's start and result in a Slack channel. |
| `SENTRY_AUTH_TOKEN` | Inbox, Flutter delivery | Optional | Reads and updates Sentry issues for the triage (`event:read`, `event:write`, `project:read`, `org:read`), and uploads an app's debug symbols. |
| `ANDROID_KEYSTORE_BASE64` | Flutter delivery | Yes | The Android signing keystore, base64. |
| `ANDROID_KEYSTORE_PASSWORD` | Flutter delivery | Yes | The keystore's password. |
| `ANDROID_KEY_ALIAS` | Flutter delivery | Yes | The signing key's alias in the keystore. |
| `ANDROID_KEY_PASSWORD` | Flutter delivery | Yes | The signing key's password. |
| `ANDROID_PLAY_STORE_JSON_KEY_BASE64` | Flutter delivery | Yes | The Google Play service account's JSON key, base64, for the upload. |
| `APPLE_DIST_CERTIFICATE_P12_BASE64` | Flutter delivery | Yes | The Apple distribution certificate, `.p12`, base64. |
| `APPLE_DIST_CERTIFICATE_PASSWORD` | Flutter delivery | Optional | The `.p12`'s password. Unset for a `.p12` exported without one (GitHub cannot store an empty secret): the delivery imports it with an empty password, re-encoding an OpenSSL-made file first. |
| `APPLE_API_KEY_ID` | Flutter delivery | Yes | The App Store Connect API key's id. |
| `APPLE_API_ISSUER_ID` | Flutter delivery | Yes | The App Store Connect issuer id. |
| `APPLE_API_KEY_BASE64` | Flutter delivery | Yes | The App Store Connect API key, `.p8`, base64, for the upload. |

Flutter delivery receives these through its caller, `kskill-deliver.yml`. Android ones start with `ANDROID_`, Apple ones with `APPLE_`; the names before v2.9.0 (`CM_*`, `PLAY_STORE_*`, `IOS_DIST_*`, `ASC_*`) are no longer read.

## On the token broker

`KSKILL_APP_PRIVATE_KEY` is a Cloudflare Worker secret, not a repository secret: the GitHub App's key in PKCS#8. A job proves who it is with its OIDC identity and receives a short-lived token, so no repository ever holds the key. See [terraform/token-broker/README.md](../terraform/token-broker/README.md).

## Variables

Every value comes from the calling repository, set as an Actions variable on the repository itself (on GitHub Free, organization variables don't reach private repositories). Secrets are above; `.github/callers.json` lists what each workflow takes.

| Name | Needed by | What |
|---|---|---|
| `KSKILL_TOKEN_BROKER_URL` | all | Required: your token broker's address |
| `KSKILL_BOT` | PR, Claude, Renovate | Required, no default: the App's bot login, `example-app[bot]`. `scripts/kskill-repo-settings.sh` writes it from `KSKILL_BOT` in its environment |
| `KSKILL_LIB_REPO` | a repository with a private library submodule | `owner/library` |
| `KSKILL_AUTOMERGE` | PR | `false` stops merging automation PRs, a library's release PR excepted |
| `KSKILL_DIST_REBUILD` | PR | `true` rebuilds a committed output on the PR's branch |
| `KSKILL_CD_STAGING`, `KSKILL_CD_PROD` | Deploy, delivery | `false` turns that environment off (`PROD`: version tags) |
| `BUILD_NUMBER_OVERRIDE` | Flutter delivery | Replaces the build number for one run |
| `SENTRY_ORG`, `SENTRY_PROJECT`, `SENTRY_REGION_URL` | Sentry triage | Which Sentry project to read |

A caller grants `id-token: write`: the broker and AWS both use the job's OIDC identity.
