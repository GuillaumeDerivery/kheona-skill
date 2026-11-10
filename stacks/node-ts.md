<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# Kheona stack extension — Node / TypeScript

Covers services (backends, often on a shared library: `.kheona.json` `workflows.library.package`) and front ends
(Next.js and others). The shared workflows are `kskill-ci.yml` (the gate, running `kskill-ci-node.yml` where a
`package.json` is at the root), `kskill-main.yml` (a push to `main`: staging; a library's runs its gate only) and
`kskill-deploy.yml` (a version tag: production).

## K1 — Toolchain

```bash
node -v && cat .nvmrc 2>/dev/null
grep -nE '"engines"|"packageManager"' package.json
grep -n "node-version" .github/workflows/*.yml     # K1.1: a number, not "lts/*" or "latest"
git ls-files --error-unmatch package-lock.json     # K1.2
grep -rn "npm ci\|pnpm i --frozen-lockfile\|yarn --immutable" .github/workflows/  # install from lock
```

Pin Node in three places that must agree: `.nvmrc`, `engines.node`, and the workflow's `node-version`.
With a Dockerfile, its `FROM node:<version>` is a fourth: the CI gate fails when it and `.nvmrc` differ, and
Renovate moves all of them in one PR (the preset's weekly group; a Node major in the majors' draft), so a Node
patch bump merges unaided.
`lts/*` is not a version — it moves the day a new LTS ships, and native modules rebuild against it.

**K1.4 — currency first; the bot is the last topic, not the first.**

**1 — Direct dependencies.**
```bash
npm outdated
```
Nothing more than one major behind without a tracking issue.

**2 — Then the rest of the tree.** `npm outdated` reports **direct dependencies only** by default. The
transitive graph is pinned in `package-lock.json` and will not move on its own:
```bash
npm outdated --all | wc -l        # the number the default view hides
npm audit --omit=dev              # K5.4 too: known-vulnerable transitives
```
Refresh with `npm update` (moves within the existing `package.json` ranges, so it cannot break an API by
construction — the K2.1 gate verifies it). `npm install <pkg>@latest` is the separate, riskier operation
that rewrites `package.json`.

> **This only becomes a standing concern once K1.2 is satisfied.** With no committed lockfile the tree
> re-resolves on every install — invisible, but self-correcting. With one it is frozen until a human
> refreshes it. **A repo that just committed its lockfile has, in the same stroke, acquired this
> obligation.** See SKILL.md K1.4.

**3 — Only now, the automation.**
```bash
cat renovate.json                                   # extends github>owner/kheona-skill//renovate/default#vX.Y.Z
gh pr list --search "head:renovate/"                # Renovate's open PRs, and whether their checks pass
```

Renovate (SKILL.md K1.4) closes item 2 for npm with weekly `lockFileMaintenance`, which a dependency bot's version
updates never did: they reach declared dependencies only. `npm audit` is still not a substitute for
`npm outdated --all`: it finds the vulnerable packages, which Renovate's alert PRs already cover.

**A `file:` dependency into a private submodule** (`"@acme/lib": "file:./submodules/lib"`, the repository named by
the `KSKILL_LIB_REPO` variable): Renovate clones the submodule with a read-only App token, so it updates npm there
too, and leaves every package the library names to the inbox's bump-lib job. Dependabot could not: its npm job failed
with `path_dependencies_not_reachable`.

**K1.5 — is the pinned Node still supported?**
```bash
node -v
curl -s https://endoflife.date/api/nodejs.json | jq -r '.[0:4][] | "\(.cycle) eol=\(.eol) lts=\(.lts)"'
npx --no-install tsc -v                 # TypeScript majors move fast too
```
An even-numbered Node major leaves Active LTS ~18 months in and goes EOL ~30 months in. Running an
odd-numbered or EOL major is a FAIL, not a style preference — it stops getting security patches.

## K2 — Pipeline

*The shared workflows build and deploy; auditing is mostly checking the callers are current
(`node ~/.claude/skills/kheona/scripts/kskill-callers.mjs check --repo .`) and `.kheona.json` `workflows.cd` is right.*

```bash
grep -nE "runs-on|needs:|if:|timeout-minutes|permissions|concurrency" .github/workflows/*.yml
gh secret list
gh api repos/:owner/:repo/rulesets                 # K2.1: is the gate required to merge?
```

For Dockerised services: the base image is pinned by **digest**, not by a floating tag
(`node:22-alpine` moves weekly). `docker build` runs in the deploy, before any rollout, so a broken Dockerfile never ships (the gate
builds it only where no deploy follows; never on a PR: a PR checks only that `.nvmrc` and the Dockerfile's node
image agree). The *built* image is tagged with the commit SHA and deployed by digest (K2.9); K8.2 rollback is the
shared deploy run by hand on the previous tag.

**K2.7 / K2.9 — image to a registry, tagged by commit SHA, deployed by digest.**
```bash
jq '.workflows.cd' .kheona.json                                       # staging and prod targets, or false
gh run list --workflow kskill-deploy.yml --limit 5 --json conclusion,headBranch,displayTitle   # K2.8: prod runs come from tags
aws ecr describe-images --repository-name <repo> --query 'sort_by(imageDetails,&imagePushedAt)[-1]' 2>/dev/null
kubectl get deploy -n <ns> -o jsonpath='{range .items[*]}{.metadata.name} {..image}{"\n"}{end}'  # each @sha256:<digest>
```
**Pass:** `kskill-deploy.yml` builds the image once, pushes it to ECR tagged with the full commit SHA (and the
version, for a release), points every deployment and cron job at its digest, waits on `kubectl rollout status`,
and reads the running image back. A repository deploying elsewhere sets `workflows.cd.target: "custom"` and keeps the
shared release check and gate. A Dockerfile that only ever gets built on a laptop is a K2.7 FAIL however clean it is.

**K2.9 — a TypeScript backend reports its commit and its version on `GET /healthcheck`.** The image says which commit
a *deployment* points at; the healthcheck says which commit the *process answering you* was built from,
reachable with nothing but `curl`. The version comes from the deploy, never from the image: one image runs on
staging (`1.4.0+3.a1b2c3d`, three commits after 1.4.0) and in production (`1.5.0`), with the same `commit`. Three
pieces, all required:

1. **The deploy passes the SHA as a build arg**: the shared deploy always passes `GIT_SHA`, then the
   environment's `workflows.cd.<env>.buildArgs`. It sets `APP_VERSION` on every deployment and cron job.
2. **The Dockerfile's runtime stage exports it**, declared last so it does not bust the layer cache:
   ```dockerfile
   ARG GIT_SHA
   ENV GIT_SHA=$GIT_SHA
   ```
3. **One helper reads it and the healthcheck returns it** — never a value baked in at build time by
   code, never `package.json`'s `version` standing in for it:
   ```ts
   // src/core/utils/build.ts -- read per call, so a test can set it
   export const runningCommit = (): string | null => {
     const sha = process.env.GIT_SHA?.trim();
     return sha ? sha : null;
   };
   export const runningVersion = (): string | null => process.env.APP_VERSION?.trim() || null;
   ```
   ```ts
   router.get('/healthcheck', (_req, res) => {
     res.status(200).send({
       version:  runningVersion(),   // APP_VERSION, set by the deploy; null outside a cluster
       commit:   runningCommit(),    // null outside an image: the honest answer
       env:      process.env.NODE_ENV,
       uptime:   process.uptime(),
       hostname: os.hostname(),      // which pod answered
     });
   });
   ```
   `runningVersion()` is the error tracker's `release` (K8.4), `runningCommit()` its `dist`, so an event names
   both. `package.json` gets `"private": true` and no `version` is read from it.

A test sets `GIT_SHA` and `APP_VERSION` and asserts `commit` and `version` echo them, and a second asserts `null`
with them unset. The deploy itself
reads the running image back from the cluster.

```bash
grep -n "GIT_SHA" Dockerfile                                  # the runtime stage exports it
grep -rn "runningCommit\|GIT_SHA" src/                        # read in one place
curl -fsS https://<host>/healthcheck | jq -r .commit,.version  # the image tag's SHA; the deploy's APP_VERSION
```
**Pass:** all three pieces present, and on a deployed pod `commit` equals the commit the deploy run
reports for that image. A healthcheck with no `commit`, or one that
returns a hardcoded string, is a FAIL.

## K3 — Code health

**The tools' shared configuration lives in this repository** (`.github/config/kskill-*`, exported by its
`package.json` as `kheona-skill/prettier`, `/knip`, `/stryker`, `/dependency-cruiser`). A Node repository takes it as a
git dependency at the version tag its callers use, nothing copied and no registry:

- `package.json`: `"devDependencies": { "kheona-skill": "github:owner/kheona-skill#vX.Y.Z" }`. Renovate's kheona-skill
  group moves this tag with the callers and the preset, in the same PR; a format change comes with its reformat there.
- `.npmrc`: `allow-git` for that source (npm 12 refuses git dependencies by default). `allow-git=root` when the
  repository's own `package.json` is the only one naming it; `allow-git=all` when a `file:` dependency (a library as a
  submodule) carries its own reference, which `root` refuses (`EALLOWGIT`). Under `root`, npm 11 also refuses to
  replace an installed git dependency: after a tag change, run that one `npm install --allow-git=all` (`npm ci` is
  fine; Renovate's own npmrc allows all). A Dockerfile that installs copies `.npmrc` with the lock file.
- The repository's own file is one line that re-exports the shared one, and overrides only what it must.

The shared Prettier options: single quotes, `printWidth: 200`, double quotes in YAML.

| Check (`workflows.ci.skip` key) | Shared config | The repository's own file |
|---|---|---|
| format | `kheona-skill/prettier` | `prettier.config.mjs`: `import base from 'kheona-skill/prettier'; export default { ...base };`; no `.prettierrc` or `prettier` key beside it; `.prettierignore` lists `*.md` and the callers (`.github/workflows/kskill-*.yml`) |
| deadCode | `kheona-skill/knip` | `knip.config.mjs`: `{ ...base, entry, project }`; script `knip --config knip.config.mjs` |
| importGraph | `kheona-skill/dependency-cruiser` | `.dependency-cruiser.cjs`: `{ extends: './node_modules/kheona-skill/.github/config/kskill-dependency-cruiser.cjs', forbidden: [its layering rules] }` |
| mutation (the inbox's mutation job, `workflows.mutation`) | `kheona-skill/stryker` | `stryker.config.mjs`: `{ ...base, commandRunner, mutate, … }`; script `stryker run stryker.config.mjs` |

An override in the repository's own file says why in a comment.

```bash
npx tsc --noEmit                                   # K3.2, must be clean
npx eslint . --max-warnings=0                      # K3.1
npx prettier --check .
grep -n '"kheona-skill"' package.json            # K3: the shared configs at the callers' tag (github:owner/kheona-skill#vX.Y.Z)
grep -n 'allow-git' .npmrc                         # npm 12 refuses git dependencies without it
grep -rn "@ts-ignore\|@ts-expect-error\|eslint-disable" src/ | grep -v "// why:"   # K3.2 suppressions
grep -rn "any" src/ --include="*.ts" | grep -vE "^\s*//" | head -30
npx knip                                            # K3.7 unused deps, files and exports (replaces depcheck + ts-prune)
# A repo whose tests import ../dist/ needs a knip.json mapping dist → src, or every test-only use
# reads as unused; and `submodules/**` ignored, or a vendored library floods the file list.
grep -n '"lint"' package.json                       # K3.1: the script CI runs carries --max-warnings=0
git status --short                                  # K3.8
```

`strict: true` in `tsconfig.json` is table stakes — check it, and check that it isn't relaxed per-file.
Add `noUncheckedIndexedAccess: true`: an index into an array or record can miss, and the type should
say so. It is the cheapest of the extra flags and the one that finds real bugs.

**K3.1 — the type-aware rules.** `tseslint.configs.recommendedTypeChecked` (with
`parserOptions.projectService: true`) at minimum, plus these, each of which maps to a defect class seen
in production:

| Rule | Catches |
|---|---|
| `@typescript-eslint/no-floating-promises` | a rejection nobody awaits — silent loss, or a dead process |
| `@typescript-eslint/no-misused-promises` | an async function where a sync callback is expected (`forEach`, an express handler without a wrapper) |
| `@typescript-eslint/restrict-plus-operands` | `+` concatenating where a sum was meant — and money summed with `+` at all |
| `@typescript-eslint/strict-boolean-expressions` | `if (blockNumber)` reading 0 as absent, `if (count)`, a `NaN` guard that never fires. Use `{ allowNullableString: true }` — `if (name)` meaning "present and non-empty" is nearly always the intent; numbers, `any` and objects are where truthiness is wrong |
| `@typescript-eslint/switch-exhaustiveness-check` | a new enum member no `switch` handles |
| `@typescript-eslint/no-unnecessary-condition` | a guard the types say can never fire — either the guard or the type is wrong |

```bash
npx eslint . --max-warnings=0 --rule '{"@typescript-eslint/no-floating-promises":"error"}' -f json \
  | jq '[.[].messages[]] | length'          # count before turning a rule on; ratchet with per-dir overrides
```
A repo with thousands of findings turns the rule on as `error` in the directories that move money or
handle vendor data first, and widens the glob — never a repo-wide `warn` that nobody reads.

Scope the type-aware block to the files `tsconfig.json` actually compiles (`files: ["src/**/*.ts"]`);
a test directory outside the program makes `projectService` error on every file in it.

**`await-thenable` finds test fakes that drifted.** Removing an `await` on a synchronous method breaks
any test whose fake of it is `async` — the stray `await` was what kept the two agreeing. Fix the fake
to match the real signature, never put the `await` back. (Measured on a production backend.)

`noUncheckedIndexedAccess` makes every ABI function on an ethers `Contract` possibly-undefined (it is
an index signature). Read them through one helper that throws a named error, rather than `!`.

**K3.11 — boundary validation.** Validate with the schema library the repo already has (zod, joi,
valibot); the parsed type is `z.infer<>` of the schema, never a hand-written interface asserted onto
`JSON.parse`. The cast check, with `src/clients|routes|modules` adjusted to the repo:
```bash
grep -rnE "\bas [A-Z]|\)!|: any\b|<any>" src/{apps,core/modules} --include="*.ts" | grep -v "// why:"
```

**K3.12 — layering.** `dependency-cruiser`, rules in `.dependency-cruiser.cjs` (extending the shared
`.github/config/kskill-dependency-cruiser.cjs`: no cycle, every import resolves), run in the gate:
```bash
npx depcruise src --config .dependency-cruiser.cjs     # exits non-zero on a forbidden edge
```
Starting rules: `core` does not import `apps`; vendor SDKs (`stripe`, `@aws-sdk/*`, `axios`, `ethers`…)
are imported only under the module/client directory; no circular dependencies (`no-circular`).

Set `options.tsPreCompilationDeps: false` so the rules run over the graph `tsc` emits: an import used
only as a type is erased and cannot deadlock module initialisation. **Don't count cycles with madge** —
it includes type-only imports. On a production backend it reported 35 cycles where 3 existed at runtime.
Set `doNotFollow` on `submodules/` (a `file:`-linked library has its own rules), and give
`enhancedResolveOptions` `exportsFields`/`conditionNames` for ESM-only packages, or they show up as
unresolvable. Check every rule fires by injecting a violation once. A rule that never fires asserts
nothing.

### K3.3–K3.6 — the design system (front end only)

**A package that renders no UI says so and passes** — "this is an API server", "this is a CLI". Say it in
the audit rather than dropping the section silently; an unstated N/A is indistinguishable from an
unexamined one.

**K3.3 — it exists and covers the categories.**
```bash
ls src/components/ui src/design-system src/styles 2>/dev/null   # this repo's equivalent
cat tailwind.config.* 2>/dev/null | head -60                    # tokens, or defaults left as-is?
```
**Pass:** tokens for colour, typography, spacing, radius, shadow and motion are defined in one place —
CSS custom properties, a Tailwind `theme.extend`, or a token module — **and** the shared components are
built from them. Tailwind installed with its stock palette is not a design system: a screen reaching for
`bg-blue-500` is picking a colour, not using a token. Likewise a component library dropped in without a
theme layer: the components are someone else's decisions, the tokens are what make them yours.

**K3.4/K3.5 — reuse, and register what is new.**
```bash
git diff --name-only main... | grep -E '^src/(app|pages|features)/'
grep -rnE "export (default )?function [A-Z][A-Za-z]*(Button|Input|Select|Modal|Dialog|Card|Badge)" \
  src/ --include="*.tsx" | grep -v "src/components/ui/"
```
**Pass:** every hit outside the design-system directory is genuinely single-use. The second screen that
wants one moves it into the system first. What moved is in the Storybook (or catalogue route) **and** the
`CLAUDE.md`.

**K3.6 — invariants.** Adjust the directory to this repo's, and declare it in `.kheona.json`'s
`designSystem.allow` so the hook runs the same rules.
```bash
grep -rnE "#[0-9a-fA-F]{3,8}\b" src/ --include="*.ts" --include="*.tsx" --include="*.css" \
  | grep -vE "globals\.css|tokens|theme"                      # literal colours outside the token layer
grep -rn "style={{" src/ --include="*.tsx"                     # inline styles bypass the system
grep -rnE "className=\"[^\"]*\b(text|bg|border|shadow)-\[" src/ --include="*.tsx"   # arbitrary Tailwind values
grep -rnE "<(button|input|select|textarea|dialog)\b" src/ --include="*.tsx" \
  | grep -v "src/components/ui/"                               # raw elements outside the system
```
The last one is the analogue of Flutter's raw-`ElevatedButton` check and catches the same failure: a
screen that needed a button five minutes ago and wrote `<button className="...">`. The arbitrary-value
check is the Tailwind-specific one — `bg-[#1a1a1a]` is a literal colour wearing a utility class, and
nothing in a stock Tailwind or ESLint setup flags it.

## K4 — Tests and coverage

```bash
npx vitest run --coverage        # or: npx jest --coverage
```

Threshold goes in the config, so a local run and CI agree:
```ts
// vitest.config.ts
coverage: {
  provider: 'v8',
  reporter: ['text', 'lcov'],
  exclude: ['**/*.d.ts', '**/generated/**', '**/*.config.*', '**/migrations/**', 'src/**/index.ts'],
  thresholds: { lines: 90, functions: 90, branches: 90, statements: 90 },  // K4.4: ratchet up to this
}
```
Jest equivalent: `coverageThreshold.global` plus `coveragePathIgnorePatterns`.

A repo whose runner is `node --test` has no threshold flag of its own; `c8` supplies both the report and
the check:

```bash
npm run coverage                                    # the suite, under c8
npx c8 check-coverage --lines 85 --functions 87     # exits non-zero below the threshold
```

In the K4 bootstrap phase (`.kheona.json` `"phase": "bootstrap"`, SKILL.md K4) a missing `coverage` or
`coverage:check` script means no tests yet, and a missed floor is a warning, in CI and in `enforce.sh full`.

### K4.2 — what the push hook needs before it can apply a floor

`enforce.sh`'s `full` tier runs the suite on **every** stack, always, floor or no floor. On Node it
additionally applies a *threshold* when `.kheona.json` declares `"coverage"`, and it applies it with
`c8 check-coverage` — the one Node coverage threshold that can be handed a number from outside the
tool's own config, so the figure in `.kheona.json` is the figure enforced rather than a second copy of
one living in a script.

A repo that sets `"coverage"` therefore owes two things:

- **a `coverage` npm script** that runs the whole suite under `c8` (`c8 node --test …`, `c8 vitest run`,
  whatever the runner is). **The hook calls it by that exact name** — a script called `test:cov` or
  `coverage:ci` is invisible to it. A failure of that script is reported as K4.1, a failing suite,
  because that is what it is; the threshold is checked separately afterwards.
- **`c8` in `devDependencies`**, resolvable through `npx --no-install`.

**Either one missing is a FAIL that names what is missing, never a pass.** A floor nothing measures is
the same manufactured confidence as a floor over the wrong denominator (SKILL.md K4.2) — with the extra
problem that the session banner then announces it.

A repo that would rather keep its threshold in its runner's own config (vitest `coverage.thresholds`,
jest `coverageThreshold`) does that by making `npm test` the command that runs coverage, and leaves
`"coverage"` out of `.kheona.json` — one gate, in one place, actually running. What is not acceptable is
the key set and nothing behind it.

The `.kheona.json` number is the **line** floor; K4.2 is a line-coverage rule. A function or branch
floor belongs in the repo's own script or config next to it (`--functions`, `--branches`), where it is
run by the same command.

**K4.3a — publish the report.** The threshold above gates the merge; CI additionally uploads the raw
report every run so "what is untested" is answerable without re-running anything:
```yaml
- uses: actions/upload-artifact@v7
  if: always()
  with: {name: coverage, path: coverage/}
```

**K4.5 first targets:** money/decimal arithmetic, request validators and schemas, auth middleware and
token verification, DTO↔entity mappers, retry/backoff logic. Route handlers tested through supertest
against a faked service layer — not against a live database.

**K4.6:** no `setTimeout` waits, no real network (`nock`/MSW), no shared DB state between test files, and
`--sequence.shuffle` (or `--randomize`) on in CI so order dependence surfaces.

**K4.7 — mutation testing.** StrykerJS (`@stryker-mutator/core`), with the runner plugin for the repo's
test runner — or the `command` runner for `node --test`, which works with any runner at the cost of
per-test coverage analysis:
```bash
npx stryker run --mutate "src/core/utils/**/*.ts" --incremental   # scope to K4.5 targets; incremental caches results
```
Read `reports/mutation/mutation.html`; every **Survived** mutant is a finding.

**The workflow** (SKILL.md K4.7 — every 2 weeks, never the PR gate) is the mutation job of the shared
[`kskill-inbox.yml`](../.github/workflows/kskill-inbox.yml), called by the repository's `kskill-inbox.yml`: no
`schedule:`, dispatched every other week (`gh workflow run kskill-inbox.yml -f job=mutation`) where `.kheona.json` has
`workflows.mutation`, from which it reads its options (npm
script, concurrency, incremental key, report path, timeout). It mutates only the files of `mutate` added or modified
since the commit of its last green run (the `mutation-base` artifact; `.github/scripts/kskill-mutation-scope.mjs`,
passed as `--mutate`): the full scope on the first run, after 90 days without one, or when the Stryker config changed;
nothing changed: the Stryker job is skipped. Not `--incremental`: with the command runner Stryker sees one opaque test
and would keep an old *Survived* after the test that kills it lands.
```jsonc
// stryker.config.mjs -- the shared options (.github/config/kskill-stryker.mjs: command runner, no coverage
// analysis, incremental, ignorePatterns, the reports the mutation job uploads) plus what is this repo's
import base from './.github/config/kskill-stryker.mjs';
export default {
  ...base,
  commandRunner: { command: 'npm run build && node --test "tests/**/*.ts"' },
  mutate: ['src/core/utils/**/*.ts'], // the K4.5 targets, nothing wider
  symlinkNodeModules: true,
  concurrency: 2,
};
```
`"mutation": "stryker run stryker.config.mjs"` in `package.json`, `@stryker-mutator/core` as a devDependency, and
`reports/` + `.stryker-tmp/` in `.gitignore`.

Audit (K4.7):
```bash
jq -e '.workflows.mutation' .kheona.json >/dev/null && test -f .github/workflows/kskill-inbox.yml && echo PASS || echo FAIL
gh run list --workflow kskill-inbox.yml -L 30 --json displayTitle,createdAt --jq '[.[] | select(.displayTitle | endswith("· mutation"))][0]'   # within two weeks
grep -n "mutation" .github/workflows/ci.yml   # must print nothing: never the PR gate
```

**Do not restore an incremental file in CI with the `command` runner.** Stryker sees the whole suite as
one opaque test, so it cannot tell that a test was added or weakened, and reuses every old verdict
for unchanged source — a mutant a new test kills keeps reading *Survived*. Either run fresh each time
or restore the file only when `tests/**`, the lockfile and the Stryker config
are unchanged. Locally, `--incremental` is fine; pass `--force` after changing a test.

**Cost, measured** (a production backend): `node --test` has no Stryker runner plugin, so the
`command` runner cannot do per-test coverage — every mutant rebuilds and runs the *whole* suite
("Ran 1 tests" in the dry run is the tell). ~30 s per mutant, ~200 mutants per large file, so tens of
minutes for two files at concurrency 6. Jest/Vitest/Mocha have plugins with `perTest` analysis and are
an order of magnitude faster. Locally, `--incremental` makes repeat runs affordable; in CI see the
warning below.

**The mutant run must use the full suite.** A trial over a hand-picked test subset reported guards as
surviving that a test outside the subset kills — a subset turns its own omissions into findings.

Sandbox traps: `ignorePatterns: ["submodules", "dist", "coverage"]` (Stryker copies the project and
cannot copy a symlinked submodule), and `npm run build`, not bare `tsc`, as the build step when the
build copies resources tests read. Run Stryker from a devDependency install, not `npx -p`: its
TypeScript preprocessor resolves `typescript` from its own location. `thresholds.break` is the
ratchet once the run time and a baseline are known — still in the weekly workflow, not the PR gate.
For a repo that runs tests against `dist/`, mutate `src` and let Stryker's build step (`buildCommand`)
recompile — mutating `dist` reports line numbers nobody can act on.

**K4.8 — property tests.** `fast-check`, inside the existing runner:
```ts
fc.assert(fc.property(fc.double({min: 0, max: 1e9, noNaN: true}), fc.integer({min: 0, max: 18}),
  (x, d) => Number(roundDown(x, d)) <= x));
```

## K5 — Secrets and supply chain

```bash
git log --all --oneline -S"BEGIN PRIVATE KEY" | head
grep -rnE "console\.(log|info)" src/ | grep -iE "token|password|secret|authorization|pan|cvv"
npm audit --audit-level=high
grep -rn "process.env" src/ | head -30            # every one validated at boot, not read ad hoc
```

Validate the whole environment once at startup (zod/envalid) and fail loudly — a service that boots with
a missing secret and fails on the first request is a K2.5 violation at runtime.

**K5.5 — disabled users** (an API with a stored User model): one middleware on the authenticated router, before every
route, loads the caller's user by the token's subject: unknown → 401, disabled → 403. Not a check inside
`/users/:userId` alone. Where the shared library provides the middleware, use it rather than a project copy (an
unknown user allowed only where an onboarding creates it); a test calls a route other than `/users/...` with a disabled user and expects 403.

**K5.6 — the real client IP** (Express): `app.set('trust proxy', N)` with N from configuration (2 behind Cloudflare
and the ALB; never `true`, which trusts every hop the client wrote), then `req.ip` is the end user. The request log
line carries `ip=<req.ip> ip_from=X-Forwarded-For[-N]`, or `ip_from=peer` when N is 0 or the chain is shorter than
N (then `req.ip` is the socket peer). Where the shared library resolves it, declare its trusted-proxy count `0` in
`config/` and set the real depth in the deployment's ConfigMap; never a hand-rolled copy. A test sends a forged
leftmost `X-Forwarded-For` and expects the trusted entry in the log.

**K5.7 — the service's User-Agent**: every outbound client (`axios.create`, `fetch` wrappers, vendor SDKs that take
one) sends `<service>/<version> (<environment>)`, the version read from `package.json` at boot, never hard-coded.
A vendor SDK with its own `User-Agent` keeps it, with ours appended where the SDK has an option for it (`appInfo`
for Stripe). `grep -rn "axios.create\|new Axios" src/` lists the clients to cover.

**OIDC settings come from the deployment, never from the repository.** The issuer, JWKS URI and audiences are
declared `""` in `config/` and set by the deployment's Kubernetes **ConfigMap** (they are public, not secrets; the
infra repository) as environment variables. Where the configuration layer only overrides a key the file declares,
the `""` is what makes the variable apply. A service fails fast at boot without them, so moving committed values out needs the ConfigMap in
infra first: file the infra issue and merge the PR only after it.

**Local runs read a gitignored `.env`** (services on the shared library, `workflows.library.package`). Every start
script (`start`, `hotstart`, and their `-cli` twins) runs `node --env-file-if-exists=.env …`: Node 24 loads the
file itself, no `dotenv` dependency, and a variable already set in the environment wins over the file. `.env`
holds the configuration variables for **local development only** (a local Mongo, test keys), never production values;
nothing that starts a service with production secrets is kept, encrypted or not. `.env.example` is committed:
every key the service takes from the environment, the keys required to boot first, then one block per vendor.
A configuration variable overrides its `config/` key **even when empty**, so every such line is commented out
(`# <PREFIX>_db_connectionString=`) and a developer uncomments only what they fill; `NODE_ENV=dev` stays active. `.gitignore` has `.env` and `.env.*` with `!.env.example`;
`.dockerignore` has `.env` and `.env.*`, so a local file never reaches an image. In a container the file is
absent, the flag does nothing, and the values come from the deployment's ConfigMap and Secret.
The only other `.env*` file a repository may hold is a committed `.env.test` with fake values (add `!.env.test`); no
`.env.staging` or `.env.prod`: reach staging with `kubectl port-forward`, never a copy of its secrets (SKILL.md K5.1).
The repository check (check 7) enforces all of this in CI.

**The MongoDB connection string comes from the environment only** (SKILL.md K5.1).
Every `config/core/*.json` declares `"db": { "connectionString": "" }` (`dev.json` may hold
`mongodb://127.0.0.1:27017/<db>` without credentials); the deployment's Secret sets its variable in each namespace; a local
run sets it in `.env` (commented out in `.env.example`); tests start `mongodb-memory-server`. The repository check
(check 9) fails on a committed URI with credentials or a remote
host, naming the file and key, never the URI.

**No other credential either**: the secret scan (gitleaks, a step of every CI; SKILL.md K5.1) fails on any key,
token, password or webhook URL in the committed files. A false positive goes in `.gitleaks.toml` or `.gitleaksignore`
with its reason; run it locally with `bash ~/.claude/skills/kheona/scripts/kskill-secret-scan.sh .`

```bash
grep -c -- '--env-file-if-exists=.env' package.json      # one per start script
git ls-files --error-unmatch .env.example                # committed
git ls-files | grep -E '(^|/)\.env($|\.)' | grep -vE '\.env\.(example|test)$'   # must print nothing
grep -qx '.env' .dockerignore && echo ok                 # never copied into an image
```


## K6 / K7 — no stack-specific commands

Review and tracker hygiene (K6) and documentation currency (K7) are identical for every stack. Apply
`SKILL.md`'s criteria directly — `gh pr list`, `gh issue list`, `git log --oneline origin/main..HEAD`, a
code-review pass on the branch, and a read of the repo's own `CLAUDE.md`/README against the code as it
is now. K6.3 has one command everywhere: `/code-review` on the full branch. **None of this is optional here just because this file carries no stack-specific commands for it.**

## K8 — Release readiness

```bash
grep -nE '"name"|"version"' package.json
npm run build
node dist/main.js --help 2>&1 | head            # or a real healthcheck hit
curl -fsS localhost:$PORT/healthcheck            # K8.4; `commit` present (K2.9)
```
K8.1: the package name, the container image name, the service name in the deploy manifest and whatever
the console shows must all agree.
