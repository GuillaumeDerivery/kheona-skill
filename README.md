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

## Reference

- [docs/kheona-json.md](docs/kheona-json.md): every `.kheona.json` key.
- [docs/secrets.md](docs/secrets.md): the variables and secrets each workflow needs.
- [docs/free-plan.md](docs/free-plan.md): the free-plan limits this is built for.
- [terraform/token-broker/README.md](terraform/token-broker/README.md): the token broker.

## License

[MPL-2.0](LICENSE). Usable in private repositories; changes to these files are published back.
