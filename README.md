<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# kheona-skill

Shared CI, delivery and repository automation for GitHub, built to work the same on GitHub Free. A repository keeps a few small caller files and one `.kheona.json`; everything else lives here, pinned by commit.

## What a repository gets

- **CI per stack:** Node, Python, Flutter, Terraform and cluster manifests, one gate per pull request.
- **Deploy:** build, push by commit SHA, roll out to EKS, read back what runs.
- **Release:** a release PR, a `ship` label, a `prod` branch that only moves forward.
- **Flutter delivery:** TestFlight and Google Play from one workflow.
- **Sentry triage:** issues and fixes from production errors.
- **Renovate:** self-hosted, with shared presets.
- **Claude review and `@claude`:** a review on automation PRs, and fixes on request.
- **The token broker:** App tokens from a job's OIDC identity, so no App key sits in any repository.

## Five-minute adoption

See [docs/adoption.md](docs/adoption.md). In short: write `.kheona.json`, run the generator, set the variables, open a PR.

```bash
node scripts/kskill-callers.mjs write --repo ../my-repo --self owner/kheona-skill --sha <40-hex-commit> --version v1.0.0
```

## Secrets

Four places hold secrets, and only the broker holds the GitHub App key. Values are never printed and never reach a public log. A caller passes each secret by name: `secrets: inherit` does not cross owners. Variables are in [docs/secrets.md](docs/secrets.md).

### On this repository

| Secret | Used by | What it does |
|---|---|---|
| `KSKILL_GUARD_TERMS` | `guard.yml` | The private list of forbidden names, one per line. The guard fails if a file, a commit or a PR's text holds one. A fork's PR never receives it. |
| `GITHUB_TOKEN` | automatic | GitHub's own token for each run. Nothing to set. |

### On the private runner repository

The runner repository calls `kskill-guard.yml`, which reads a fork's PR here without running it.

| Secret | What it does |
|---|---|
| `KSKILL_GUARD_TERMS` | The same list, so a fork's PR is checked too. |
| `STATUS_TOKEN` | A token that may set the generic `guard` commit status on this repository's PRs. |

### On each repository with the `kheona-skill` or `kskill` topic

Set only what the repository uses. A workflow that lacks a required secret fails with its name before any real work starts; an optional one only turns its feature off.

| Secret | Needed by | Required | What it does |
|---|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | PR, `@claude`, inbox | Optional | Signs Claude Code in, for the review of automation PRs, `@claude` and the fixes of the Sentry triage. Without it there is no review. |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Deploy | Only without `awsRoleArn` | A stored AWS key for ECR and EKS. Prefer `awsRoleArn` in `.kheona.json`: the job then uses its OIDC identity and neither secret exists. |
| `SLACK_WEBHOOK_URL` | Deploy | Optional | Announces each deploy's start and result in a Slack channel. |
| `SENTRY_AUTH_TOKEN` | Inbox, Flutter delivery | Optional | Reads and updates Sentry issues for the triage (`event:read`, `event:write`, `project:read`, `org:read`), and uploads an app's debug symbols. |
| `ANDROID_KEYSTORE_BASE64` | Flutter delivery | Yes | The Android signing keystore, base64. |
| `CM_KEYSTORE_PASSWORD` | Flutter delivery | Yes | The keystore's password. |
| `CM_KEY_ALIAS` | Flutter delivery | Yes | The signing key's alias in the keystore. |
| `CM_KEY_PASSWORD` | Flutter delivery | Yes | The signing key's password. |
| `PLAY_STORE_JSON_KEY_BASE64` | Flutter delivery | Yes | The Google Play service account's JSON key, base64, for the upload. |
| `IOS_DIST_CERTIFICATE_P12_BASE64` | Flutter delivery | Yes | The Apple distribution certificate, `.p12`, base64. |
| `IOS_DIST_CERTIFICATE_PASSWORD` | Flutter delivery | Yes | The `.p12`'s password. |
| `ASC_KEY_ID` | Flutter delivery | Yes | The App Store Connect API key's id. |
| `ASC_ISSUER_ID` | Flutter delivery | Yes | The App Store Connect issuer id. |
| `ASC_API_KEY_BASE64` | Flutter delivery | Yes | The App Store Connect API key, `.p8`, base64, for the upload. |

Flutter delivery also passes these through the ship workflow, so an app sets them once.

### On the token broker

`KSKILL_APP_PRIVATE_KEY` is a Cloudflare Worker secret, not a repository secret: the GitHub App's key in PKCS#8. A job proves who it is with its OIDC identity and receives a short-lived token, so no repository ever holds the key. See [terraform/token-broker/README.md](terraform/token-broker/README.md).

## Reference

- [docs/kheona-json.md](docs/kheona-json.md): every `.kheona.json` key.
- [docs/secrets.md](docs/secrets.md): the variables each workflow reads.
- [docs/free-plan.md](docs/free-plan.md): the free-plan limits this is built for.
- [terraform/token-broker/README.md](terraform/token-broker/README.md): the token broker.

## License

[MPL-2.0](LICENSE). Usable in private repositories; changes to these files are published back.
