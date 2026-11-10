<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# Kheona stack extension — Python

Covers Python services (Pipenv + pytest + pylint). The shared workflows are `kskill-ci.yml` (the gate, running
`kskill-ci-python.yml` where a `Pipfile` or `pyproject.toml` is at the root), `kskill-main.yml` (a push to `main`:
staging) and `kskill-deploy.yml` (a version tag: production).

## K1 — Toolchain

```bash
python --version && cat .python-version 2>/dev/null
grep -nA3 "\[requires\]" Pipfile                   # or [project].requires-python in pyproject.toml
grep -n "python-version" .github/workflows/*.yml   # K1.1: an explicit x.y, never "3.x"
git ls-files --error-unmatch Pipfile.lock          # K1.2 (or poetry.lock / uv.lock)
pipenv install --deploy --ignore-pipfile           # fails if the lock is out of sync with Pipfile
```

`--deploy` is the check that matters: it refuses to install when `Pipfile.lock` no longer matches
`Pipfile`, which is exactly the drift that makes a CI build differ from a laptop.

**K1.4 — currency first; the bot is the last topic, not the first.**

**1 — Direct dependencies.**
```bash
pipenv update --outdated
```
Nothing more than one major behind without a tracking issue.

**2 — Then the rest of the tree.** `Pipfile` lists what you asked for; `Pipfile.lock` pins everything
those packages dragged in, and those pins do not move on their own:
```bash
pipenv requirements | wc -l       # the full pinned set, not just what Pipfile names
pipenv check                      # K5.4 too: known-vulnerable transitives
```
Refresh with `pipenv update` (re-resolves within the existing `Pipfile` constraints, so it cannot break
an API by construction — the K2.1 gate verifies it). Editing `Pipfile` is the separate, riskier move.

> **This only becomes a standing concern once K1.2 is satisfied.** Before the lock is committed the tree
> re-resolves on every install — invisible, but self-correcting. After, it is frozen until a human
> refreshes it. **A repo that just committed its lockfile has, in the same stroke, acquired this
> obligation.** See SKILL.md K1.4.

**3 — Only now, the automation.**
```bash
cat renovate.json                                  # extends github>owner/kheona-skill//renovate/default#vX.Y.Z
gh pr list --search "head:renovate/"               # Renovate's open PRs
```
Renovate (SKILL.md K1.4) updates the Pipfile's packages and `.python-version`, and its weekly
`lockFileMaintenance` refreshes `Pipfile.lock` whole, transitives included (item 2).
Every Pipfile entry is an exact pin (`==x.y.z`, the locked version), never `~=` or `*`: Renovate's OSV
vulnerability lookup reads the Pipfile only and skips a range (the preset's pipenv `rangeStrategy: pin` turns one
back into a pin PR). Check (prints nothing):
```bash
python3 -c 'import tomllib; p=tomllib.load(open("Pipfile","rb")); [print(n, v) for s in ("packages","dev-packages") for n, v in p.get(s, {}).items() if not (v if isinstance(v, str) else v.get("version", "")).startswith("==")]'
```

**K1.5 — is the pinned Python still supported?**
```bash
python --version
curl -s https://endoflife.date/api/python.json | jq -r '.[0:5][] | "\(.cycle) eol=\(.eol)"'
```
Each Python minor gets five years. An EOL minor is a FAIL — no security patches, and the wheels for new
dependency versions stop being built for it before that.

## K2 — Pipeline

*The shared workflows build and deploy; auditing is mostly checking the callers are current.*

Same as the core section. For Dockerised services, pin the base image by digest; the deploy builds the image before any
rollout (the gate builds it only where no deploy follows, never on a PR: stacks/node-ts.md K2).

**K2.7 / K2.9 — image to a registry, tagged by commit SHA, deployed by digest.**
```bash
jq '.workflows.cd' .kheona.json
gh run list --workflow kskill-deploy.yml --limit 5 --json conclusion,headBranch,displayTitle   # K2.8: prod runs come from tags
```
**Pass:** same bar as any backend ([node-ts.md](node-ts.md) K2.7) — built once by the shared deploy, pushed tagged
by the full commit SHA, deployed by digest (K2.9), behind the gate. For a library rather
than a service, the destination is PyPI (or an explicit, written "internal only, never published").

## K3 — Code health

```bash
pipenv run pylint --rcfile=pylintrc <package>      # K3.1/K3.2, must score clean
pipenv run black --check . && pipenv run isort --check-only .
pipenv run mypy <package>                          # K3.2 — if absent, adding it is a finding
git status --short                                 # K3.8
grep -rn "# type: ignore\|# pylint: disable" --include="*.py" . | grep -v "# why:"
grep -rn "except\s*:" --include="*.py" .           # bare excepts swallow K2.5 failures
git status --short
```

**K3.3–K3.5 (design system).** N/A for a library, a CLI or an API service — say so explicitly. A
Python package that *does* render UI (a Django/Jinja front end, a Streamlit or Dash app) is held to the
same bar: tokens in one place, shared components/templates reused rather than re-styled per page, and
`stacks/static-web.md`'s K3.6 greps run over its templates and stylesheets.

## K4 — Tests and coverage

```bash
pipenv run pytest --cov=<package> --cov-report=term-missing --cov-fail-under=90
```

Configure once so local and CI agree:
```ini
# pytest.ini / setup.cfg
[coverage:run]
omit = */migrations/*, */generated/*, */__init__.py, */conftest.py
[coverage:report]
fail_under = 90        ; K4.4: start at today's number and ratchet
```

In the K4 bootstrap phase (`.kheona.json` `"phase": "bootstrap"`, SKILL.md K4) pytest's exit 5 (no test
collected) passes and a coverage below `coverageFloor` is a warning, in CI and in `enforce.sh full`.

**K4.3a — publish the report.** The threshold above gates the merge; CI additionally uploads the raw
report every run so "what is untested" is answerable without re-running anything:
```yaml
- uses: actions/upload-artifact@v7
  if: always()
  with: {name: coverage, path: coverage.xml}
```

Add `--cov-report=xml` alongside `term-missing` so there is a file to upload.

**K4.5 first targets:** decimal/money handling, pydantic validators and schema coercion, auth and token
verification, serializers/mappers, and any state machine. Endpoint tests through the framework's test
client against faked dependencies — not a live database.

**K4.6:** `pytest -p no:randomly --count=2` (or `pytest-randomly` left on) to surface order dependence;
freeze time with `freezegun` rather than sleeping; block the network (`pytest-socket`).

**K4.7 — mutation testing:** `mutmut run --paths-to-mutate <package>/money` then `mutmut results`;
every surviving mutant is a finding. Report first, gate later.
The inbox's mutation job (SKILL.md K4.7) is Node-only today; a Python repository runs mutmut by hand and
records the result. UNVERIFIED: no shared Python mutation job exists yet.

**K4.8 — property tests:** `hypothesis` (`@given(st.decimals(...))`) for money, rounding and any
encode/decode pair.

**K3.11/K3.12:** pydantic models at every boundary (never `cast()` or a `TypedDict` asserted onto
`json.loads`); `import-linter` contracts for layering, run in the gate.

## K5 — Secrets and supply chain

```bash
git log --all --oneline -S"BEGIN PRIVATE KEY" | head
grep -rnE "logger\.(info|debug)|print\(" --include="*.py" . | grep -iE "token|password|secret|key"
pipenv check          # or: pip-audit
```

**Local runs read a gitignored `.env`** (as in [node-ts.md](node-ts.md) K5). `.env`
holds **local development values only**; `.env.example` is committed with every environment variable the service
reads (`os.environ`, `os.getenv`, its settings class), headed "Copy to .env for local runs. Development values only,
never production ones. .env is gitignored." An empty variable usually replaces a default with `""`, so every line is
commented out but harmless local defaults (`ENV=dev`). Pipenv loads `.env` itself for `pipenv run` and `pipenv
shell` (its values **override** the shell's), so `make run` needs nothing more; without Pipenv, `set -a; . ./.env;
set +a`. Say so in the README and CLAUDE.md run sections. `.gitignore` has `.env`, `.env.*` and `!.env.example`;
`.dockerignore` has `.env` and `.env.*`. A committed `.env.test` (fake values) is the only other allowed file; no
`.env.staging` or `.env.prod`, whose values live in the cluster (SKILL.md K5.1). The repository check (check 7)
enforces it in CI.

**A MongoDB connection string comes from the environment only** (SKILL.md K5.1): the settings read it from a variable
(`os.environ`), its default at most `mongodb://localhost:27017/<db>` without credentials, and the deployment's Secret
sets it. The repository check (check 9) fails on a committed URI with credentials or a remote host in a config
file (`*config*.py`, `*settings*.py`, `.env*`, YAML, TOML, INI), naming the file and key, never the URI.

**No other credential either**: the secret scan (gitleaks, a step of every CI; SKILL.md K5.1) fails on any key,
token, password or webhook URL in the committed files. A false positive goes in `.gitleaks.toml` or `.gitleaksignore`
with its reason; run it locally with `bash ~/.claude/skills/kheona/scripts/kskill-secret-scan.sh .`

```bash
git ls-files --error-unmatch .env.example                                     # committed
git ls-files | grep -E '(^|/)\.env($|\.)' | grep -vE '\.env\.(example|test)$'   # must print nothing
grep -qx '.env' .dockerignore && echo ok                                      # never copied into an image
```


**K5.6 — the real client IP**: one helper resolves it and one ASGI middleware logs it. `TRUSTED_PROXY_COUNT` (2 behind Cloudflare and the
ALB) picks the address that many entries from the right of `X-Forwarded-For`, a shorter chain falls back to the peer,
and an ASGI middleware logs `--> METHOD PATH ip=… ip_from=X-Forwarded-For[-2] ua="…"` for every request, rejected
ones included. Werkzeug's `ProxyFix(x_for=N)` is the same rule for a Flask/WSGI app.
**K5.7 — the service's User-Agent**: one `requests.Session` or `httpx.Client` per remote, created with
`headers={"User-Agent": f"{SERVICE}/{__version__} ({ENVIRONMENT})"}`; a bare `requests.get` sends
`python-requests/2.x`. `grep -rn "requests\.\(get\|post\)\|httpx\.\(get\|post\)" --include=*.py .` lists the calls
still outside a session.

## K6 / K7 — no stack-specific commands

Review and tracker hygiene (K6) and documentation currency (K7) are identical for every stack. Apply
`SKILL.md`'s criteria directly — `gh pr list`, `gh issue list`, `git log --oneline origin/main..HEAD`, a
code-review pass on the branch, and a read of the repo's own `CLAUDE.md`/README against the code as it
is now. K6.3 has one command everywhere: `/code-review` on the full branch. **None of this is optional here just because this file carries no stack-specific commands for it.**

## K8 — Release readiness

```bash
pipenv run python -c "import <package>; print(<package>.__version__)"
docker build -t <svc>:audit . && docker run --rm <svc>:audit --help
curl -fsS localhost:$PORT/health                   # K8.4
```
