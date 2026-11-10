<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# Adopting kheona-skill

## Once per owner (organization or account)

Every owner runs its own GitHub App and its own token broker. Nothing is shared: an App's key mints tokens for every installation of that App, so one App can't safely serve two people's brokers.

1. **A GitHub App**, private to the owner. No webhook. Repository permissions, read and write: Actions, Variables, Administration, Checks, Commit statuses, Contents, Issues, Pull requests, Workflows; read: Metadata, Dependabot alerts. Install it on the repositories that use kheona-skill. Its bot login is `<app-slug>[bot]`.
2. **The token broker**, a Cloudflare Worker (free plan) holding the App's key: [terraform/token-broker/README.md](../terraform/token-broker/README.md). Its policy lists `owner/kheona-skill` (the workflows' repository) in `workflowRepositories` and the owner in `owners`.
3. **No organization variables:** on GitHub Free they don't reach private repositories, so every value below is set on each repository.

## Each repository: the setup command

From a checkout of this repository at a release tag, and a clean clone of yours on its default branch:

```bash
KSKILL_BOT='<app-slug>[bot]' KSKILL_TOKEN_BROKER_URL=https://<your-broker> \
  bash scripts/kskill-setup.sh owner/repo ../repo            # checks, changes nothing
KSKILL_BOT='<app-slug>[bot]' KSKILL_TOKEN_BROKER_URL=https://<your-broker> \
  bash scripts/kskill-setup.sh --apply owner/repo ../repo    # does what is missing
```

It goes through the steps below, says `ok`, `done` or `todo` for each, and is safe to re-run: every step checks first,
so a run stopped anywhere resumes where it stopped. What only a person can do, it walks through:

- **The App installed** on the repository: read from GitHub for an organization (with `admin:org`); on a personal
  account GitHub shows it to no one but the App, so in a terminal it says where to look and asks once. The answer is
  kept in the clone's `.git/kskill-setup.state`, never committed.
- **Variables:** `KSKILL_BOT` and `KSKILL_TOKEN_BROKER_URL`, set from the shell with `--apply`, read back from the
  repository on a later run.
- **Secrets, by name only:** the ones a workflow here fails without. For each missing one it says what it is, where to
  find it, the exact command, and what goes wrong. With `--apply` in a terminal it waits while you run the command in
  another terminal (Enter: check the name again, `s`: skip, `q`: stop here), one secret at a time. **It never reads,
  asks for, prints or stores a value**: `gh secret set NAME --repo owner/repo` asks for it, hidden, and a file is
  encoded straight into gh: `base64 < cert.p12 | tr -d '\n' | gh secret set IOS_DIST_CERTIFICATE_P12_BASE64 --repo owner/repo`.
- **A Flutter app's store secrets** (Android: the upload keystore, its password, alias and key password, the Play
  service account's JSON key; iOS: the distribution `.p12` and its password if it has one, the App Store Connect key id,
  issuer id and `.p8`). The Android signing secrets count under either name, `ANDROID_KEYSTORE_PASSWORD`,
  `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` or their older `CM_*` names; it asks for the ones this version's deliver
  workflow reads. The pitfalls it names: a `.p12` without a password leaves `IOS_DIST_CERTIFICATE_PASSWORD` unset
  (GitHub cannot store an empty secret); macOS's `/usr/bin/openssl` is LibreSSL and cannot read a modern PKCS#12
  (Homebrew's OpenSSL 3 can, with `-legacy` for an older RC2-encrypted file); with no Java installed, `keytool` ships
  with Android Studio (`/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool`).

It ends by opening one PR with what it wrote (a re-run finds that PR again): its CI is the proof. A caller's header
names this command (`Do not edit: run scripts/kskill-setup.sh --apply again.`).

The steps, by hand:

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

2. **Releases:** `release-please-config.json` and `.release-please-manifest.json` at the root, the manifest seeded at the current version on several lines (`{\n  ".": "1.4.0"\n}`: release-please keeps that indent, while a one-line manifest comes back compact and fails Prettier), and squash merges only (the settings script sets it). See the README's "Releases and deploys".
3. **Caller files**, one per event. The stack is read from the repository:

   ```bash
   node scripts/kskill-callers.mjs write --repo . --self owner/kheona-skill --sha <40-hex-commit> --version v2.0.0
   ```

4. **`renovate.json`:** `{"extends": ["github>owner/kheona-skill//renovate/default#v2.0.0"]}`: the generator pins the preset at the callers' version.
5. **Variables and secrets:** `KSKILL_TOKEN_BROKER_URL` (your broker) and `KSKILL_BOT` (your App's `<app-slug>[bot]`) are required; neither has a default. `KSKILL_BOT=<app-slug>[bot] scripts/kskill-repo-settings.sh owner/repo --apply` writes it with the other settings. The rest: see [secrets.md](secrets.md) and the [README](../README.md#secrets). Callers pass secrets by name; `secrets: inherit` does not cross owners. The App key is never one of them. A Flutter app signs for Android with `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`; the older Codemagic names `CM_KEYSTORE_PASSWORD`, `CM_KEY_ALIAS`, `CM_KEY_PASSWORD` still work for now, with a deprecation warning: set the new ones to the same values, then delete the old.
6. **Shared configs (Node):** `"kheona-skill": "github:owner/kheona-skill#v2.0.0"` in `devDependencies`, `allow-git=root` in `.npmrc` (`all` where a `file:` dependency names it too; moving the tag by hand: `npm install --package-lock-only` first) and a one-line `prettier.config.mjs` re-exporting `kheona-skill/prettier` (single quotes, `printWidth: 200`). See [stacks/node-ts.md](../stacks/node-ts.md) K3.
7. **Topic:** add `kheona-skill` or `kskill`. A library's consumers add the topic the library's `.kheona.json` names.
8. **Prove it:** open a test PR. It must pass CI and review, and merge.

`node scripts/kskill-callers.mjs check --repo .` says when a caller is missing or differs from what its version expects. Renovate opens one PR per release of this repository, moving every caller and the preset pin; when a version changes a caller's content, CI says so and `scripts/kskill-setup.sh --apply` (or `kskill-callers.mjs write`) rewrites it.
