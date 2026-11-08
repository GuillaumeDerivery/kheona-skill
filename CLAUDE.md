<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# kheona-skill

## First rule: this repository references nothing outside itself

No other repository, organization, account, Sentry project, host, domain, cluster, bucket, account id or person, in code, comments, tests, fixtures, docs, commit messages, issues or PRs. It may name itself, `<owner>/kheona-skill`, in badges and examples. Tests use `owner/repo`, `example-cluster`, `111122223333`.

Whatever a workflow needs about the outside world comes from the calling repository: `.kheona.json`, Actions variables, secrets passed by name. Never a default here. The guard (`.github/scripts/kskill-guard.mjs`) enforces it; its list is private and never enters this repository.

## What this is

Reusable workflows, composite actions, the scripts they run, shared tool configs, Renovate presets and the token broker. A repository calls them through small generated caller files, pinned by commit SHA.

Every owner brings its own GitHub App and token broker; this repository never names either. `KSKILL_BOT` (the App's `<app-slug>[bot]`) and `KSKILL_TOKEN_BROKER_URL` are required repository variables with no default. The guard accepts one App as an author: `<this repository's name>[bot]`, the App that releases this repository; its commit messages are still scanned.

## Working here

- `bash test/run-all.sh` runs every test. CI runs the same.
- Workflows reach their own actions with `$/.github/actions/x`, and their files through `KSKILL_HOME` (`.github/actions/kskill-home`): the job's working directory is the caller's checkout.
- A new secret or input goes through `.github/callers.json`, regenerated with it, so caller files stay exact.
- Third-party actions are pinned by SHA.
- Issues and PRs: the first line says it all; anything more goes in a "Details" section.

## KPIs

Every run records numbers: fixes landed, "Needs you" items per day, deploy duration, Claude cost. A change to the automation says which KPI it moves; one that moves none is questioned.
