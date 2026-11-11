<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# kheona-skill

Shared CI, delivery and repository automation for GitHub, built to work the same on GitHub Free. A repository keeps a few small caller files and one `.kheona.json`; everything else lives here, pinned by commit.

## What a repository gets

- **CI for every stack:** Node, Python, Flutter, Terraform and cluster manifests, one gate per pull request. One shared workflow per job (`kskill-ci.yml`, `kskill-main.yml`, ...) reads the stack from the repository's files and `.kheona.json`: a caller never names it.
- **Deploy:** build, push, roll out to EKS by image digest, read back what runs. Or hand over to the repository's own deploy.
- **Release:** release-please's release PR; a person merges it, the version tag releases to production.
- **Flutter delivery:** TestFlight and Google Play from one workflow.
- **Sentry triage:** issues and fixes from production errors.
- **Renovate:** self-hosted, with shared presets.
- **Claude review and `@claude`:** a review on automation PRs, and fixes on request.
- **The token broker:** App tokens from a job's OIDC identity, so no App key sits in any repository.

## Five-minute adoption

See [docs/adoption.md](docs/adoption.md). Once per owner: your own GitHub App and token broker. Then per repository, the setup command: `scripts/kskill-setup.sh [--apply] owner/repo <clone>` checks each step (`.kheona.json`, the topic, the App installed, release files, callers and `renovate.json`, settings, variables, secrets by name), does what it can, walks a person through the rest (an app's store secrets one at a time: what each is, where to find it, the exact `gh secret set` command; it never reads a value), and opens the PR that proves it. Safe to re-run: it resumes where it stopped.

```bash
node scripts/kskill-callers.mjs write --repo ../my-repo --self owner/kheona-skill --sha <40-hex-commit> --version v2.0.0
```

## Releases and deploys

| When | Workflow in the repository | What happens |
|---|---|---|
| A PR is opened or updated | `kskill-pr.yml` | CI. Nothing deploys. |
| A merge to `main` | `kskill-main.yml` | CI, then **staging** (a service; an app has none). |
| A merge to `main` | `kskill-release-please.yml` | release-please opens or updates the release PR: version and CHANGELOG, with a "Check before you merge" list. |
| **A person merges the release PR** | `kskill-release-please.yml` | The version tag `vX.Y.Z` and the GitHub release, made with the App token. |
| The tag is pushed | `kskill-deploy.yml` or `kskill-deliver.yml` | The release check, then **production**: a service runs the image staging tested (the release commit changes only versions; `APP_VERSION` is set at deploy), else the full gate and a build. An app is built (TestFlight and Play). |
| Started by hand on an earlier tag | the same | A rollback: the release's own image when ECR still holds it. An app fixes forward. |
| **In a fork, a person publishes a release** (the parent's version, on `main`) | the same | The release check, the full gate, then **production**. Release-please never runs in a fork. |
| Started by hand on `main` (an app) | `kskill-deliver.yml` | A test build, no version. |

- **The environment comes from the ref, never from an input:** `main` is staging, a version tag is production, nothing else deploys (`.github/scripts/kskill-release-check.sh`).
- **A tag deploys only a person's release:** `vMAJOR.MINOR.PATCH`, on `main`, the newest, the squash merge of release-please's PR merged by a person with write access, and Main passed on the commit before it (still running: the check waits for it, up to 45 minutes). The release PR runs the gate like any PR, and its checklist names a submodule's versions and calls out a major one. A rollback, and a fork's release, need a published release and a person with write access. Tags cannot be protected on every plan, so the workflow checks.
- **A library** releases itself: its release PR merges once its gate passed (`workflows.releasePlease.merge`); the tag deploys nothing.
- **Production callers pin this repository by its immutable version tag**, so an AWS role can trust only those versions: `token.actions.githubusercontent.com:job_workflow_ref` like `<owner>/kheona-skill/.github/workflows/kskill-deploy.yml@refs/tags/v2.*`, with `sub` `repo:<owner>/<repo>:ref:refs/tags/v*`. Prove the exact value with a dry run before tightening a trust policy.
- **A custom deploy:** `workflows.cd.target: "custom"`. The release check and the gate stay here; the repository's own workflow (`workflows.cd.custom.workflow`, default `deploy.yml`, `on: workflow_call` with the inputs `environment` and `version`) deploys, with its own credentials.
- **This repository** releases the same way (`release.yml`): a person merges its release PR, the release is immutable, and each repository gets it through one Renovate PR that moves its callers, its preset pin and, in a Node repository, its `kheona-skill` devDependency together. Renovate's post-upgrade step then writes the callers again with the generator of the new version (`scripts/kskill-callers-regenerate.mjs`), so a caller whose content changes arrives right in that PR. That step is the running Renovate workflow's, so its caller must be on a version that has it (v2.7.0 on); a run behind the latest release warns.

## Secrets

Four places hold secrets, and only the broker holds the GitHub App key. Values are never printed and never reach a public log. A caller passes each secret by name: `secrets: inherit` does not cross owners. Variables are in [docs/secrets.md](docs/secrets.md).

### On this repository

| Secret | Used by | What it does |
|---|---|---|
| `KSKILL_GUARD_TERMS` | `guard.yml` | The private list of forbidden names, one per line. The guard fails if a file, a commit or a PR's text holds one. A fork's PR never receives it. |
| `GITHUB_TOKEN` | automatic | GitHub's own token for each run. Nothing to set. |

### On the private runner repository

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

### On each repository with the `kheona-skill` or `kskill` topic

Set only what the repository uses. A workflow that lacks a required secret fails with its name before any real work starts; an optional one only turns its feature off.

| Secret | Needed by | Required | What it does |
|---|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | PR, `@claude`, inbox | Optional | Signs Claude Code in, for the review of automation PRs, `@claude` and the fixes of the Sentry triage. Without it there is no review. |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Deploy | Only without `awsRoleArn` | A stored AWS key for ECR and EKS. Prefer `awsRoleArn` in `.kheona.json`: the job then uses its OIDC identity and neither secret exists. |
| `SLACK_WEBHOOK_URL` | Deploy | Optional | Announces each deploy's start and result in a Slack channel. |
| `SENTRY_AUTH_TOKEN` | Inbox, Flutter delivery | Optional | Reads and updates Sentry issues for the triage (`event:read`, `event:write`, `project:read`, `org:read`), and uploads an app's debug symbols. |
| `ANDROID_KEYSTORE_BASE64` | Flutter delivery | Yes | The Android signing keystore, base64. |
| `ANDROID_KEYSTORE_PASSWORD` | Flutter delivery | Yes | The keystore's password. Replaces `CM_KEYSTORE_PASSWORD`, still read as a deprecated fallback. |
| `ANDROID_KEY_ALIAS` | Flutter delivery | Yes | The signing key's alias in the keystore. Replaces `CM_KEY_ALIAS`, still read as a deprecated fallback. |
| `ANDROID_KEY_PASSWORD` | Flutter delivery | Yes | The signing key's password. Replaces `CM_KEY_PASSWORD`, still read as a deprecated fallback. |
| `ANDROID_PLAY_STORE_JSON_KEY_BASE64` | Flutter delivery | Yes | The Google Play service account's JSON key, base64, for the upload. Replaces `PLAY_STORE_JSON_KEY_BASE64`, still read as a deprecated fallback. |
| `APPLE_DIST_CERTIFICATE_P12_BASE64` | Flutter delivery | Yes | The Apple distribution certificate, `.p12`, base64. Replaces `IOS_DIST_CERTIFICATE_P12_BASE64`, still read as a deprecated fallback. |
| `APPLE_DIST_CERTIFICATE_PASSWORD` | Flutter delivery | Optional | The `.p12`'s password. Unset for a `.p12` exported without one (GitHub cannot store an empty secret): the delivery imports it with an empty password, re-encoding an OpenSSL-made file first. Replaces `IOS_DIST_CERTIFICATE_PASSWORD`, still read as a deprecated fallback. |
| `APPLE_API_KEY_ID` | Flutter delivery | Yes | The App Store Connect API key's id. Replaces `ASC_KEY_ID`, still read as a deprecated fallback. |
| `APPLE_API_ISSUER_ID` | Flutter delivery | Yes | The App Store Connect issuer id. Replaces `ASC_ISSUER_ID`, still read as a deprecated fallback. |
| `APPLE_API_KEY_BASE64` | Flutter delivery | Yes | The App Store Connect API key, `.p8`, base64, for the upload. Replaces `ASC_API_KEY_BASE64`, still read as a deprecated fallback. |

Flutter delivery receives these through its caller, `kskill-deliver.yml`. Android ones start with `ANDROID_`, Apple ones with `APPLE_`; with only an old name set, each delivery warns that it is deprecated: set the new one to the same value, then delete the old.

### On the token broker

`KSKILL_APP_PRIVATE_KEY` is a Cloudflare Worker secret, not a repository secret: the GitHub App's key in PKCS#8. A job proves who it is with its OIDC identity and receives a short-lived token, so no repository ever holds the key. See [terraform/token-broker/README.md](terraform/token-broker/README.md).

## Use as a Claude Code skill

The repository is also the `kheona` skill (`SKILL.md`, `stacks/`, the `enforce.sh` hooks):

```bash
git clone https://github.com/<owner>/kheona-skill ~/.claude/skills/kheona
```

`/kheona` audits a repository, lands the mechanical fixes, files an issue for each failure left and reports; `/kheona report` only reports.

## Reference

- [docs/kheona-json.md](docs/kheona-json.md): every `.kheona.json` key.
- [docs/secrets.md](docs/secrets.md): the variables each workflow reads.
- [docs/free-plan.md](docs/free-plan.md): the free-plan limits this is built for.
- [terraform/token-broker/README.md](terraform/token-broker/README.md): the token broker.

## License

[MPL-2.0](LICENSE). Usable in private repositories; changes to these files are published back.
