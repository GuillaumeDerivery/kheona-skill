---
name: kheona
description: Use when scaffolding a new repository, auditing an existing one, or preparing a release — Flutter, Node/TypeScript, Python, Terraform or static web — and you need the standing bar for pinned toolchains, CI gating, unit tests with ≥90% coverage, secrets hygiene, tracker state, documentation currency and release readiness, wired through kheona-skill's shared workflows (production from version tags) — or when triaging production errors from Sentry into GitHub issues and PRs.
---

<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# The Kheona standard

**A rule that is not a command is not a rule.** Every item below is settled by running its command and reading the
output, never inferred from a `CLAUDE.md`, a README, a previous session or "we always do that". A repository passes an
item only when its command passes today.

**Running an app means build, launch, report in words, stop.** No screenshot unless the user asks for one in that turn;
when a check needs screen contents, use the accessibility tree or the app's logs. If only a screenshot could settle it,
stop and hand the check to the person watching the screen.

## When to use

- **Day one of a repository**: this is the setup contract. K1, K2.1, K3.1, K4 (in its bootstrap phase), and K3.3 when the
  repository renders a UI: the design system is the one item that cannot be retrofitted cheaply. Wire the shared
  workflows the same day ([docs/adoption.md](docs/adoption.md)).
- **Before a release**: a full pass.
- **Inheriting or resuming a repository** not touched recently.
- **Triaging production errors** ("list the Sentry issues", "work on the crashes"): *Sentry triage* below, end to end.
- **CI broke for no visible reason**: usually K1 (an unpinned toolchain moved) or K2.4 (an unpinned action moved).

Not for reviewing one diff (`/code-review`) or debugging one failure.

## Modes: pick one, state it up front

| Mode | Behaviour |
|---|---|
| `AUDIT` | Report only. Change nothing. |
| `FIX` | Audit, then land every mechanical, low-risk fix. Stop and ask on judgement calls. One commit per section. |
| `ISSUES` | Audit, then open one GitHub issue per failing item (template below). Do not also fix. |

Every item is **PASS**, **FAIL** or **UNVERIFIED** (only a person, a device or a console can settle it: say what
would). In the K4 bootstrap phase the K4 items read **DEFERRED (bootstrap)**. Items are independent; one failure never
stops the pass. Group by section, FAILs first. Never round up: "mostly passing" is a FAIL with a note.

## Stack files

The sections below are stack-agnostic. The command for each item is in the stack file: **read the one that applies
before running anything.**

| Stack | File |
|---|---|
| Flutter / Dart | [stacks/flutter.md](stacks/flutter.md) |
| Node / TypeScript (incl. Next.js) | [stacks/node-ts.md](stacks/node-ts.md) |
| Python | [stacks/python.md](stacks/python.md) |
| Terraform / infra | [stacks/terraform.md](stacks/terraform.md) |
| Static web / Cloudflare Workers | [stacks/static-web.md](stacks/static-web.md) |

A stack with no file still gets audited with its idiomatic equivalents, and the pass writes its stack file.

## What this repository provides

The skill and the automation are one repository. A repository does not build its own pipeline: it keeps a few
generated caller files and one `.kheona.json`, and calls the shared workflows here, pinned by commit SHA (the
production callers by their immutable version tag).

| Need | Where |
|---|---|
| Adopting it (once per owner, then per repository) | [docs/adoption.md](docs/adoption.md) |
| Every `.kheona.json` key | [docs/kheona-json.md](docs/kheona-json.md) |
| Variables and secrets | [docs/secrets.md](docs/secrets.md), [README](README.md#secrets) |
| What runs when (PR, `main`, release, tag) | [README](README.md#releases-and-deploys) |
| Free-plan constraints | [docs/free-plan.md](docs/free-plan.md) |
| The token broker (App tokens from a job's OIDC identity) | [terraform/token-broker/README.md](terraform/token-broker/README.md) |
| Generate or check a repository's callers | `node scripts/kskill-callers.mjs write\|check --repo <dir>` |
| What a repository must carry, and its local rules | `bash scripts/kskill-repo-check.sh <repo> <this clone>` |
| Repository settings | `bash scripts/kskill-repo-settings.sh owner/repo [--apply]` |
| Remote version audit (K1.5) | `bash scripts/kskill-versions.sh [--machine]` |
| Secret scan (K5.1) | `bash scripts/kskill-secret-scan.sh <repo>` |

From a repository, this clone is `~/.claude/skills/kheona`: `bash ~/.claude/skills/kheona/scripts/kskill-repo-check.sh . ~/.claude/skills/kheona`.

---

## Enforcement: the rules run without anyone invoking this skill

`enforce.sh`, at this repository's root, is the same rules as Claude Code hooks:

| When | Tier | Checks |
|---|---|---|
| Session start | `rules` | injects the K-rule digest and what this repository's `full` tier really runs |
| After every `Write`/`Edit` | `fast` | on the file just touched: K3.6 design-system invariants (from the repository's declared allow-list), K3.2 unjustified suppressions, K5.2 secrets in log statements, an edit to a generated caller |
| Before `git commit` | `gate` | K3.1 format, K3.1/K3.2 lint and typecheck, across the repository |
| Before `git push` | `full` | `gate`, plus the K4.1 suite always and the K4.2 floor where the stack can enforce one |

It detects the stack (`pubspec.yaml` flutter, `Pipfile`/`pyproject.toml` python, `package.json` node, `*.tf`
terraform, `wrangler.*` static) and exits silently where there is none, so one hook config is safe anywhere. Its
`.kheona.json` keys (`blocking`, `coverage`, `tiers`, `designSystem`, `phase`) are in
[docs/kheona-json.md](docs/kheona-json.md). Wire it in each repository's `.claude/settings.json` (settings are not
inherited from a parent directory):

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "bash \"$HOME/.claude/skills/kheona/enforce.sh\" rules" }] }],
    "PostToolUse": [{ "matcher": "Write|Edit", "hooks": [{ "type": "command",
      "command": "bash \"$HOME/.claude/skills/kheona/enforce.sh\" fast \"$(jq -r '.tool_input.file_path')\"" }] }],
    "PreToolUse": [{ "matcher": "Bash", "hooks": [
      { "type": "command", "if": "Bash(git commit*)", "command": "bash \"$HOME/.claude/skills/kheona/enforce.sh\" gate" },
      { "type": "command", "if": "Bash(git push*)", "command": "bash \"$HOME/.claude/skills/kheona/enforce.sh\" full" }] }]
  }
}
```

- **A repository with no `designSystem` block gets no design-system checks**, and `gate` says so once. A built-in
  allow-list of one repository's file names passes there and fails everywhere else; declaring the block *is* the
  repository stating which files are its design system.
- **`coverage` is only the threshold.** Absent means no floor, never no tests: `full` runs the suite either way. A floor
  the stack cannot enforce is refused loudly (Flutter has none, K4.2; Node needs a `coverage` script under c8).
- **`blocking: true` only once `gate` already passes.** A blocking gate over a non-compliant repository denies every
  commit, and the next thing anyone does is delete the hook.
- **Hooks bind Claude in this harness and nothing else.** Not a person's `git commit`, not another machine. The only
  enforcement that binds everyone is CI (K2.1).

This repository is gated the same way: `bash test/run-all.sh` (every test, shellcheck, actionlint), run by CI on every
PR, and the Guard on every PR and push.

**Periodic jobs have no `schedule:`.** The inbox (`kskill-inbox.yml`: Sentry triage, mutation testing, the Flutter SDK
refresh, the security scan, a library bump, a fork's upstream sync) is started by a notice from another repository or by
a dispatch, `gh workflow run kskill-inbox.yml -f job=<job>`, from the owner's own scheduler at the cadence each job
states. Which jobs a repository needs: `scripts/kskill-repo-check.sh --json`, key `jobs`.

---

## K1: the toolchain is pinned and derived, not chosen

- **K1.1 One runtime version, stated in one place, identical everywhere.** Local, CI and documentation name the same
  number, and CI pins it: never `latest`, `stable` or `lts/*`. A channel is not a version: when it moves, a green
  pipeline turns red with no commit to blame.
- **K1.2 A lockfile is committed and CI installs from it** (`--frozen`, `ci`, `--locked`).
- **K1.3 Derived versions are read off the toolchain, never picked.** Where the framework publishes what it supports
  (Flutter's Gradle/AGP/Kotlin triple), those are the values: not the newest, not what a bot opened a PR for.
- **K1.4 Dependencies are current, and only then automated.** In this order; the bot is the closing topic, never the
  opening one.
  1. **Direct dependencies:** nothing more than one major behind without a tracking issue saying why.
  2. **The whole graph:** read the summary line the tool prints (`N upgradable dependencies are locked to older
     versions`), not only the direct table. Never `| head` above it. A committed lockfile (K1.2) freezes transitives
     until someone refreshes them, so it needs refreshing on a schedule.
  3. **The automation: self-hosted Renovate** (`kskill-renovate.yml`, dispatched daily), over every repository with
     the topic `kheona-skill` or `kskill` that carries a `renovate.json` (forks get updates through their upstream
     sync). The policy is one preset; the repository's `renovate.json` extends it at the callers' version
     (`{"extends": ["github>owner/kheona-skill//renovate/default#vX.Y.Z"]}`) and holds only its own deviations:

     | Update | What happens |
     |---|---|
     | minor, patch, pin, digest | one PR a week for the whole repository (Monday), every ecosystem, labelled `automerge`: `kskill-pr.yml` merges it once CI passed at that commit and Claude's review did not block it |
     | major, or a `0.x` minor | one draft PR (`renovate/major-all`) for a person |
     | transitives | `lockFileMaintenance`, Thursday, merged like a minor |
     | a known vulnerability | its own PR at once, any day, labelled `security` (OSV) |
     | a new Python minor | its own draft (`.python-version`, the Docker image and Pipfile's `python_version` together) |
     | Flutter/Dart SDK, Gradle, AGP, Kotlin | left alone: the inbox's refresh-flutter job (K1.3) |
     | this repository's callers and preset pin | one PR per release, moving them together, merged by a person |

     Updates are `fix(deps)`, so release-please carries them into the next release PR. Where nothing may merge on its
     own (`.kheona.json` `workflows.automerge.enabled: false`) the repository extends `renovate/no-automerge.json`; a
     `role: infra` repository extends `renovate/infra.json` ([stacks/terraform.md](stacks/terraform.md)). Dependabot is
     off (`config/repo-settings.json`): Renovate opens the security PRs. Its OSV lookup needs one exact version per
     direct dependency, so **every Pipfile entry is an exact pin** (`==2.9.0`); the preset turns a range into a pin PR.
     Renovate maps no pub ecosystem to OSV: a Flutter app's advisories come from OSV-Scanner on the pub lockfiles (the
     Flutter CI on a lockfile change, and the inbox's weekly security scan).
- **K1.5 The framework itself is current and still supported.** K1.1 passes a repository pinned to a two-year-old
  runtime; this asks whether anyone still supports it. Runtime/SDK, framework, CI runner image and language level each
  have their own clock. Record current, one behind with a reason, or overdue with a tracking issue. *Not knowing* is the
  failure. **Run `scripts/kskill-versions.sh`, don't answer by hand**: it asks each upstream and puts it beside the
  machine and the repository's pins, with the fix commands (`--machine`: this machine only). The Android triple is
  exempt from "latest": it is read off the installed Flutter SDK, and matching upstream is a bug.
- **K1.6 Evolution is automated end to end.** Each link that applies exists and has run at least once: Renovate's PRs
  (K1.4); a library's release notifying the repositories that use it (`workflows.releasePlease.notify`), each opening
  its own bump PR (the inbox's bump-lib job); a parent's push notifying its forks (`kskill-sync-upstream.yml`), each
  receiving an upstream-sync PR; this repository's releases reaching every repository through one Renovate PR. A link
  that cannot apply says why in `CLAUDE.md`.

## K2: CI/CD is a gate, least-privilege, pinned, and released deliberately

The shared workflows satisfy K2 by construction. Auditing a repository on them is mostly checking it is on them, at a
current version, with nothing hand-edited: `node scripts/kskill-callers.mjs check --repo .` and
`bash scripts/kskill-repo-check.sh . <this clone>`.

- **K2.1 A gate runs on every PR**: format, lint, typecheck, tests, coverage threshold (K4). On a paid plan or a public
  repository it is a required status check on `main`. **On GitHub Free a private repository has no branch protection or
  rulesets** (`403 Upgrade to GitHub Pro`): record the gate as advisory by platform constraint, not a FAIL to retry. A
  deploy still `needs:` its gate, so what is unprotected is the push, not the deploy ([docs/free-plan.md](docs/free-plan.md)).
- **K2.2 Deploy and publish jobs need the gate and never run from a pull request.** The gate runs once per tree: on a
  push to `main` it passes at once when a green PR run tested that exact tree (`.github/scripts/kskill-tested-tree.sh`),
  and runs in full otherwise. A version tag always runs it in full. Never skipped when unsure.
- **K2.3 Signing and deploy credentials are inventoried**: where each lives, when it expires, how to regenerate it.
  Anything unrecoverable (a keystore, a root key) has an off-machine backup. Every secret a workflow references exists,
  and every one that exists is referenced. Prefer OIDC (`awsRoleArn`, the token broker) to stored keys: no repository
  holds an App key.
- **K2.4 The pipeline is pinned and bounded.** Actions by commit SHA, tools at exact versions, runner images pinned
  (`ubuntu-24.04`, not `-latest`), `permissions: contents: read` with writes per job, `timeout-minutes` on every job,
  a `concurrency` group with `cancel-in-progress` on pull requests only.
- **K2.5 Failures name themselves.** A missing secret fails in seconds with its name. A build that dies mid-step after
  silent minutes is read as resource exhaustion first: print memory and disk.
- **K2.6 What shipped is reported back**: version and build number in the run summary, read out of the built artifact.
- **K2.7 Every project ships from CI, to a real destination, never from a laptop.**

  | Stack | Destination |
  |---|---|
  | iOS / Android app | TestFlight and Google Play (internal track at least), signed, `kskill-deliver.yml` |
  | Backend | a container registry, then the cluster (`kskill-deploy.yml`, EKS), or the repository's own deploy (`workflows.cd.target: "custom"`) after the shared release check and gate |
  | Static site | the edge that serves it |
  | Library | its registry, or a written "internal only, never published" |
  | Infrastructure | `terraform apply` by a person (or Terraform Cloud); CI validates only |

  **Pass:** the destination is named, the job reaching it needs the gate, the latest release reached it, signed where
  the platform requires. A repository with no publish path says so; nobody having thought about it is a FAIL.
- **K2.8 Production comes from a version tag, never from a merge to `main`.** `main` takes every merge and deploys
  **staging** at most (a service; an app has none). release-please keeps a release PR open (version, CHANGELOG, a
  "Check before you merge" list); **a person merging it is the release**: it creates the tag `vX.Y.Z` and the GitHub
  release with the App token, and the tag's push starts `kskill-deploy.yml` or `kskill-deliver.yml`. The environment
  comes from the ref, never an input (`.github/scripts/kskill-release-check.sh`): `main` is staging, a version tag is
  production, nothing else deploys. A tag deploys only a person's release: `vMAJOR.MINOR.PATCH` on `main`, the newest,
  the squash merge of release-please's PR by a person with write access, staging passed on the commit before.
  A rollback is the same workflow started by hand on an earlier tag (the release's image digest, when the registry still
  holds it); an app fixes forward. A fork releases production from a release a person publishes (the parent's version,
  on `main`). A library's release PR merges once its gate passed (`workflows.releasePlease.merge: "gate"`); its tag
  deploys nothing. There is no `prod` branch.

  *Why:* publishing on every merge spends the CI budget on releases (a macOS minute bills 10×, and the deploy budget
  and the gate budget are the same budget), burns finite version numbers (a TestFlight build cannot be deleted, a Play
  version code cannot be reused, Apple caps uploads per day), and leaves no staging step: merged means shipped. Where
  a deploy is cheap and idempotent (a static site, `terraform apply`) the third reason still holds.

  **No `paths-ignore` on a release trigger**: a release whose files all match the filter produces no run, no
  notification and no release, while looking like one that worked.

  **Pass:** the repository's callers are current (`kskill-callers.mjs check`), `release-please-config.json` and
  `.release-please-manifest.json` exist, squash merges are on, nothing deploys production from a branch, and the last
  production run came from a tag.
- **K2.9 A container image names its commit, and the cluster runs exactly what was pushed.** The image is tagged with
  the full commit SHA (and the version, for a release) and every deployment and cron job is pointed at its **digest**:
  a tag can be overwritten, a digest cannot. The deploy waits for each rollout (`kubectl rollout status`), reads the
  running image back from the cluster, and fails when it differs. The service reports its commit at runtime (Node:
  `GET /healthcheck` `commit`, from the `GIT_SHA` build argument; `workflows.cd.<env>.healthcheckUrl` makes the deploy
  compare it). Rollback (K8.2) is the previous release's digest. Pinning a **base** image by digest in `FROM` is
  separate and stays required.
- **K2.10 Shared workflows are called, never copied.** A repository's `.github/workflows/kskill-*.yml` are small
  caller files generated by `scripts/kskill-callers.mjs` from `.github/callers.json`, one per event, pinned to this
  repository by commit SHA (production callers by version tag). What differs between repositories is `.kheona.json`
  (`role`, `workflows.*`), never an edited caller. What a repository needs follows from what it is (its stack and
  `role`): `node scripts/kskill-callers.mjs list --repo .`. Any other workflow is declared with its reason in
  `workflows.local`; an undeclared one fails the repository check. A version bump is one Renovate PR moving every
  caller and the preset pin; when a version changes a caller's content, CI says so and `write` regenerates it on that
  branch. `enforce.sh fast` flags an edit to a caller the moment it is written.
  **Pass:** `kskill-callers.mjs check` and the repository check are green on `main`.
- **K2.11 Repository settings are declared once and applied by one script.** `config/repo-settings.json` lists each
  setting with its reason (squash merges, head branches deleted, no wiki, Actions on, the workflow token read-only,
  Dependabot off, the labels the automation uses, the `KSKILL_*` variables derived from `.kheona.json`). A repository
  departs from it only in `.kheona.json` `settings`, with a reason. Nothing in it needs a paid plan.
  **Pass:** `scripts/kskill-repo-settings.sh owner/repo` prints `repository settings OK`.

## K3: code health

- **K3.1 Lint and format are configured, shared and clean**, the same rule set across repositories of a stack,
  generated and vendored paths excluded, both in the gate. The script CI calls is strict (`--max-warnings=0` or the
  stack's equivalent). Where the stack has type-aware rules (dropped promises, `+` on non-numbers, truthiness on
  numbers, non-exhaustive switches) they are on; the stack file names them.
- **K3.2 Static analysis and typecheck are clean**, no blanket suppression; each remaining one says why.
- **K3.3 A repository that renders a UI has a design system, and it is the only source of UI primitives.** One place
  owns colour, typography, spacing, radius, elevation and motion as named tokens, *and* the shared components built
  from them (button, field, select, dialog, sheet, card, list row, empty and loading states). A repository that renders
  nothing says so and passes; nobody having thought about it is a FAIL.
- **K3.4 Reuse first; something new goes into the system, not the screen.** *Generic core, local override:* what every
  call site shares is baked in (states, shape, the busy/disabled contract); what varies is a parameter with a default.
  Needing another colour is a parameter to add, never a fork of the component.
- **K3.5 Every shared component is registered** in the repository's component index (a catalogue screen, a Storybook)
  *and* its `CLAUDE.md`.
- **K3.6 Project invariants are commands that return nothing**, run in the gate and in `enforce.sh fast`: the
  design-system rules, layering, "never call X directly". A rule held in prose is broken by the first screen built in a
  hurry. The stack file lists the starting set; the repository declares its allow-list in `.kheona.json`
  `designSystem`. A Flutter app's configuration is a `static const` in `lib/core/config/app_config.dart`, and nothing
  outside that folder reads a build define or dotenv ([stacks/flutter.md](stacks/flutter.md)).
- **K3.7 No dead weight**: unused dependencies, files, exports, assets, commented-out blocks. As a command (the stack
  file names the tool), or each on an issue recording the decision.
- **K3.8 The working tree is clean** and nothing sits unpushed.
- **K3.9 No hardcoded business rule values.** A threshold, a limit, a ratio is a named constant in the one place the
  repository keeps them, listed in its `CLAUDE.md`.
- **K3.10 No hardcoded user-facing strings.** Everything a user can see, locale-picked asset paths included, comes from
  the localization layer. Debug-only screens are the one exception.
- **K3.11 Data from outside the process is validated where it enters, never cast**: a runtime schema at the boundary,
  and only the checked value carries the domain type. No cast (`as`, `!`, `any`, `cast()`, `# type: ignore`) in the
  client, route or handler directories without a `// why:`.
- **K3.12 Layering rules are a command** over the import graph, run in the gate (the stack file names the tool).

## K4: tests and coverage ≥ 90 %

**Bootstrap phase.** A new repository is built before it is tested: `.kheona.json` `"phase": "bootstrap"` (absent
means `established`). CI still runs format, lint, typecheck and build, and the tests that exist; the coverage floor is
reported, not enforced; no mutation testing; `enforce.sh full` does the same; an audit reads the K4 items DEFERRED.
**The first production release enforces the switch**: the gate on a version tag and a library's release refuse while
in bootstrap (`.github/scripts/kskill-phase.sh --ship`). On switching, the floor starts at the measured figure (K4.4).

- **K4.1 A real test suite exists** (not the generated placeholder) and passes.
- **K4.2 Line coverage ≥ 90 %, over the whole app, generated code filtered out.** Two corrections, both needed:
  generated code (clients, models, i18n bundles, migrations) is excluded before computing; and **files nothing imports
  must be counted**. Several toolchains only instrument what a test reaches, so an untested file is absent rather than
  0 %, and the figure reads several times higher than the truth. Before believing a number, compare the source-file
  count with the report's. A ratchet over the wrong denominator is worse than no floor.
- **K4.3 The threshold is enforced in CI**, not printed in a terminal. Every stack except Flutter.
- **K4.3a Every stack uploads the raw coverage report** as an artifact, `if: always()`. Reading it (which files are
  absent) is a local act, never a CI step that grows a filter and a percentage.
  **Flutter has no coverage target and no threshold** (it still uploads): `flutter test --coverage` omits every library
  no test imports (measured ~4×: 10.9 % reported, 2.6 % real), and the generated import-everything test that fixes it
  was tried and removed. Quoting a Flutter percentage is a FAIL. Flutter is held to K4.1, K4.3a, K4.5 and K4.6, tracked
  by *what* is covered. Pure-Dart packages have a working threshold and get no exception.
- **K4.4 Coverage is a ratchet, never a cliff.** Start at today's measured number, raise it in each PR that adds tests,
  one tracking issue for the climb to 90. Never lowered.
- **K4.5 Cover the expensive logic first**: money arithmetic and rounding, validators, auth and token-expiry decisions,
  API↔domain mappers, state machines over a faked dependency. UI and E2E tests are welcome and are not how you reach 90.
- **K4.6 Tests are deterministic**: no sleeps, no real network, no shared mutable fixtures, no order dependence.
- **K4.7 Mutation testing shows the tests fail when the code is wrong.** Coverage says a line ran, not that an
  assertion depends on it. The inbox's mutation job, switched on by `workflows.mutation`, dispatched every two weeks,
  mutates only the `mutate` files changed since its last green run and uploads the report. A report, never the PR gate;
  scope `mutate` to the K4.5 targets so it fits its timeout.
- **K4.8 Arithmetic and parsing get property-based tests**: state the invariant (rounding down never exceeds the input,
  `decode(encode(x)) == x`) and let the generator find the input nobody would type.
- **K4.9 One boot test runs against state shaped like the deployed one**, not only an empty database: indexes, schema
  and data left by the previous release are what a deploy starts against. Pair it with K2.9's rollout wait.

## K5: secrets, privacy, supply chain

- **K5.1 No credential in the repository or its history.** Checked by the repository check and the secret scan in
  every CI run (`scripts/kskill-repo-check.sh`, `scripts/kskill-secret-scan.sh`); each check has a
  `workflows.ci.skip.<key>` with a reason.
  - **Environment files** (`envFiles`): only `.env` (local, gitignored), `.env.example` (committed, no working value)
    and optionally `.env.test` (fake values). No `.env.staging` or `.env.prod`: those values live in the cluster; reach
    staging with `kubectl port-forward`. `.gitignore` has `.env`, `.env.*`, `!.env.example`; `.dockerignore` has
    `.env`, `.env.*`. A deployed backend commits `.env.example`; a Node service on the shared library
    (`workflows.library.package`) starts with `node --env-file-if-exists=.env`.
  - **git-crypt covers every secret file** (`gitCrypt`), where git-crypt is used: every file under `secrets/`, named
    `*secret*.y(a)ml` or `*.secret`, or holding a `kind: Secret`, has `filter=git-crypt` **and** is stored encrypted
    (its blob starts with `\0GITCRYPT\0`). A file committed before its rule stays plaintext until re-added, and its
    values are rotated. A backup or archive is emptied instead: every value the literal `GITLEAKS_SECRET_REPLACED`.
  - **No database connection string** (`mongoUri`): it comes from the environment (the deployment's Secret, locally
    `.env`). A committed URI with credentials or a non-local host fails, reported by file and key, never the URI.
  - **No credential of any kind** (`secretScan`): gitleaks, pinned and checksum-verified, on the committed tree. A
    false positive is allowlisted in `.gitleaks.toml` or `.gitleaksignore` with its reason. Findings name the file,
    line and rule, never the value. A credential ever committed is rotated: history keeps it.
- **K5.2 Sensitive values are never logged in non-debug builds**: tokens, passwords, card data, personal data.
  Redaction is gated on a build flag; debug dumps to disk are skipped, not redacted.
- **K5.3 Every declared permission, scope and data-collection claim can be defended**, audited on the merged manifest:
  dependencies inject permissions.
- **K5.4 No known-vulnerable dependency** ships without a tracked exception.
- **K5.5 A disabled user gets 403 on every route** of an API that stores users: every authenticated request loads the
  caller (unknown 401, disabled 403), not only `/users/:id`. A token outlives the decision to disable its owner.
- **K5.6 Every backend logs each request's real client IP and where it read it** (`X-Forwarded-For[-2]`,
  `CF-Connecting-IP`, or `peer`). The trust depth is configuration, equal to the proxies that append to
  `X-Forwarded-For`, counted from the **right** (never the leftmost entry, which the client writes; a shorter chain
  falls back to `peer`). The origin is reachable only through those proxies. The load balancer logs the device's IP too
  (a WAF web ACL with logging, `Authorization` and `Cookie` redacted), since its access logs see only the CDN.
  *Check:* `curl -s -H 'X-Forwarded-For: 192.0.2.1' https://<host>/<health path>`; the log shows your address and its
  origin, never `192.0.2.1`.
- **K5.7 Every client names itself in its `User-Agent`**: `<client>/<version> (<detail>)`, e.g.
  `Acme-Android/2.4.0 (build 412; Android 15)`, `acme-backend/1.9.0 (production)`. Set once on the shared HTTP client,
  never per call, never a library default. A browser sends it in `X-Client`. Never a user id, email or token in it.
- **K5.8 An infra repository carries a current posture audit** of its live account and cluster: one open issue,
  `Infra audit: …`, one box per gap, each with its command, output and what "done" is, refreshed monthly; fixes stay a
  person's job. The checks: [stacks/terraform.md](stacks/terraform.md), "Posture audit".
- **K5.9 Every domain has its DNS in code and its email security strict.** Records in the infra repository's IaC,
  never the dashboard. A mail domain: one SPF ending `-all`, aligned DKIM ≥ 2048 bits per sender, DMARC
  `p=reject; sp=reject; adkim=s; aspf=s` with a `rua` someone reads, MTA-STS `enforce` and TLS-RPT. A domain that sends
  no mail: null MX, `v=spf1 -all`, the same DMARC, an empty `*._domainkey`. Every domain: DNSSEC with its DS at the
  registrar. The only state short of this is a dated alignment step in a tracked issue. Commands:
  [stacks/terraform.md](stacks/terraform.md), "Domains".

## K6: review and tracker hygiene

- **K6.1 No stale open PRs**: each has an owner and a stated reason it is still open.
- **K6.2 Every open issue is triaged**: labelled; one open on purpose behind an outside blocker is `[PARKED] …`.
- **K6.3 A full review of the current branch** against its merge base (`/code-review`), nothing surviving
  verification. Record what was reviewed and at what effort.
- **K6.4 Issues and PRs are written for a fresh Claude session** (below); the PR names its issue on its first line.
- **K6.5 Sentry and GitHub point at each other**: every unresolved Sentry issue that is a real defect has a linked
  GitHub issue; every resolved one names the PR that resolved it, or why it was noise.
- **`@claude` works in every repository** (`kskill-claude.yml`): a person with write access mentions it on an issue
  (Claude opens a `claude/issue-<n>-…` PR, never merged by it) or a PR (Claude commits to its branch, never a fork's,
  never `main`). Every PR an automation opens gets Claude's review in `kskill-pr.yml` once CI passed: one comment, a
  verdict, at most five `path:line` findings; a blocking one drafts the PR and keeps it from the merge.

## K7: documentation is current

- **K7.1 `CLAUDE.md` and README describe the code as it is now**: versions, open issues, resolved items moved out.
- **K7.2 Narrative goes to `HISTORY.md`**, current state to `CLAUDE.md`. A fact lives in one file, linked from others.
- **K7.3 Anything not confirmed live is marked UNVERIFIED.**
- **K7.4 A fresh clone can be brought up** from the documented steps alone.
- **K7.5 Project knowledge lives in the project's `CLAUDE.md`, never in assistant memory.** Check (prints nothing):
  `ls -A "$HOME/.claude/projects/$(pwd | tr '/' '-')/memory" 2>/dev/null`. If it prints files, move what is true into
  `CLAUDE.md` and delete them. A user's own `~/.claude/CLAUDE.md` is theirs, not memory.

## K8: release and deploy readiness

- **K8.1 Identity is consistent**: package, bundle and service identifiers, display names and versions agree across
  files and with the consoles that own them.
- **K8.2 Rollback is defined in one sentence.** On the shared deploy: run `kskill-deploy.yml` by hand on the previous
  tag.
- **K8.3 A smoke test passes on every target**: it builds and starts. The interactive pass is a person's; never claim it.
- **K8.4 Errors reach somewhere a person looks.** Propose [Sentry](https://sentry.io) by name rather than asking which
  vendor; an existing tracker passes. Use the SDK's automatic capture, plus one seam for the failures the project
  catches and recovers from. **Upload symbols on every release, in the job that built the artifact**, or the traces
  are hex. Don't turn on obfuscation or debug-info splitting before an upload is proven against a real event. Keep the
  SDK's defaults from sending what K5.2 forbids.
  - **One Sentry project per application**; the environment is a parameter at init, never a second project.
  - **Release builds only, staging and production only**: the SDK starts when the DSN is non-empty *and* the build is a
    release (Flutter `kReleaseMode`, a production `NODE_ENV` or an environment flag the deploy sets). A store's internal
    track is `staging`. Debug or simulator events in Sentry are themselves a FAIL.
  - **The DSN:** a compiled app may commit it (it ships in the binary anyway; Flutter: `AppConfig.sentryDsn`). A
    deployed service reads it only from the deployment's Secret, the key declared empty in its config; the repository
    check warns on a committed one. Check the Secret's DSN is this application's project (the id after the last `/`).
  - **A repository meant to be forked** carries the whole integration with an empty DSN; a fork supplies its DSN.

  **Pass:** someone can say who watches it; release builds only; automatic capture on; one seam; symbols uploaded in the
  publish lane; and a deliberate error in a **release** build seen arriving with a readable stack.
- **K8.5 Monitoring comes with its triage, in the repository.** The Actions variables `SENTRY_ORG`, `SENTRY_PROJECT`
  (and `SENTRY_REGION_URL` off sentry.io) and the secret `SENTRY_AUTH_TOKEN` (`event:read`, `event:write`,
  `project:read`, `org:read`; an upload-only `org:ci` token cannot) turn on the inbox's sentry-triage job, dispatched
  daily. A deterministic step lists every unresolved issue of the last 90 days with the GitHub issues and PRs naming it;
  Claude Code, never given the token, runs *Sentry triage* below on each new one: one GitHub issue per real one, noise
  filed and closed (`sentry-noise`), fix PRs (`fix/sentry-<slug>`, a test that fails without the fix, the gate green),
  at most three per run, the rest labelled `sentry: fix deferred`. Sentry then follows GitHub: resolved in the next
  release when a merged PR names it, resolved when closed as fixed, ignored until it escalates when closed as noise.
  **It never merges.** In a fork, a fix to code shared with the parent goes to the parent.

---

## Writing issues and PRs

The reader is Claude in a fresh session, holding the repository and nothing else.

- No preamble, no summary of what you just did, no emoji, no closing line.
- Facts, paths, commands: `src/foo.ts:42`, the exact command, its real output.
- One claim per line; bullets over paragraphs; a table when there are columns.
- No empty adjectives ("robust", "comprehensive", "properly").
- What was tried and rejected goes in only when it stops the next session repeating it.
- Omit an empty section; never "N/A".
- Mark UNVERIFIED (K7.3). Never paste a secret or a file holding one.
- **The first line says it all**; anything more goes in a "Details" section.
- **An issue lives where its fix lands.** A fork's defect in code shared with its parent is filed in the parent; what
  is the fork's own (its deploy values, its secrets, its workflow runs) in the fork, never the reverse.
- **Parked:** title `[PARKED] …`, body opening `## Status: parked`, the blocker, the unblock condition as a checklist.
- **Waiting:** label `waiting`, first body line `Waiting on: <issue, PR, person or event>`. Drop it when unblocked.

### Issue template (`ISSUES` mode)

One issue per failing item; the title names the fix, not the symptom.

```markdown
**Title:** <imperative fix, e.g. "Pin the runtime version in CI instead of `latest`">

## What's wrong
<the observed state, not the theory>

## Evidence
<the exact command and its actual output>

## Why it matters
<the concrete failure this causes or risks>

## What "done" looks like
- [ ] <specific, checkable change>
- [ ] <the command above now passes>
- [ ] <CLAUDE.md updated if this changes documented state>
```

Reuse the repository's labels. Don't file what `FIX` mode would settle in minutes, or what an open issue covers.

### PR body template

```markdown
Fixes #<n>.
<!-- or: Relates to #<n>: <what this PR does NOT settle>. -->

<one imperative line: what changed>

## Details
- <change, by behaviour or by file>

Verified: <command> → <result>
```

**The issue reference is the first line, always**, including when the PR does not fix it (a reproducing test, a
workaround, a partial fix). A test that deliberately asserts known-bad behaviour names its issue in its own comment.

## Sentry triage: production errors to reviewed PRs

Unattended, the inbox's sentry-triage job does steps 1–4 every day and settles Sentry from GitHub's state (K8.5). In a
session, read Sentry from the session through the Sentry MCP; never ask a person to copy from its UI.

1. **List.** `search_issues(query='is:unresolved', period='90d')`: a table (short ID linked, title, users/events, last
   seen), split into **Real** (a defect that reached a user, or could) and **Noise** (smoke tests, probes, debug-only
   asserts from a simulator, store pre-launch emulators, an event a merged PR already fixed). Classify from the event
   (environment, release, device, timestamp against the fix commit), never the title; unsettled is UNVERIFIED and
   stays Real.
2. **Dispatch one agent per Real issue, in parallel** (`isolation: "worktree"`, in the background, all in one message).
   Each pulls the issue and its events, finds the root cause with `path:line` (or says what would settle it and opens
   no PR), proves an event predates a merged fix (then reports it as noise), files the GitHub issue, fixes on
   `fix/sentry-<slug>` with a test that fails without the fix, runs the gate, and opens a PR. **Never merges**, never
   changes Sentry. One Sentry issue, one GitHub issue, at most one PR. A judgement call is filed as options.
3. **GitHub issue**, Sentry on its first line:
   `Sentry: [<SHORT-ID>](<url>) — <users> users / <events> events, last seen <date>, <platform/release>.`
   then What's wrong, Evidence, Root cause (`path:line` or UNVERIFIED), What "done" looks like.
4. **PR**, the issue and Sentry on its first two lines: `Fixes #<n>.` then `Sentry: [<SHORT-ID>](<url>)`.
5. **Close the loop in Sentry**: `link_issue` to the GitHub issue, then to the PR (without Sentry's GitHub integration
   it fails: `add_issue_note` with both URLs instead). Resolve only once the PR is **merged**, as
   `resolvedInNextRelease`: `main` ships nothing until the next version tag (K2.8). "Merge #<pr>" on a linked chain
   covers it all: retarget stacked PRs to `main`, merge with checks green, confirm the issue closed, resolve in Sentry.
6. **Noise**, once a person confirms the bucket: resolved with the reason; recurring noise filtered or ignored.
7. **Report**: one table, Sentry ID → bucket → GitHub issue → PR → Sentry state, then every UNVERIFIED item and
   decision waiting on a person.

## Common mistakes

| Mistake | Why it fails |
|---|---|
| Marking items PASS from `CLAUDE.md` | Documentation records what was true once. Run the command. |
| A 90 % gate over an untested repository | Blocks every merge, disabled within a week. Ratchet (K4.4). |
| Trusting a coverage % without checking the denominator | Untested files are often absent, not 0 %: compare file counts first. |
| "Mostly green" | Not a status. PASS, FAIL or UNVERIFIED. |
| Auditing K1.4 by opening `renovate.json` first | The bot is the last of three topics. Read the currency, transitive line included. |
| `| head` on a dependency report | The `N upgradable dependencies are locked` line below the table is a finding. |
| Editing a generated caller | The next `kskill-callers.mjs check` fails. Change `.kheona.json`, or this repository. |
| Deploying production from `main` or a branch | Production comes from a version tag a person's release created (K2.8). |
| Fixing in `ISSUES` mode, filing in `FIX` mode | The mode is the contract. |
| A PR naming its issue only mid-body | First line, or the link is found only by reading the diff. |
| Auditing the source manifest | Dependencies inject permissions you never wrote (K5.3). |
| Resolving a Sentry issue when the PR opens | Resolve on merge, as `resolvedInNextRelease`. |
| Filing a GitHub issue for an emulator crash | Noise is resolved or filtered in Sentry with a reason. |
| Skipping a section because the stack file is missing | Write the stack file; it is part of the pass. |
| Saving a project rule to assistant memory | Invisible to the next clone and every fork. Write it in `CLAUDE.md` (K7.5). |
