# Changelog

## [2.1.1](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.1.0...v2.1.1) (2026-11-09)


### Bug Fixes

* **renovate:** mint the owner's token through the broker's across-owners grant ([#24](https://github.com/GuillaumeDerivery/kheona-skill/issues/24)) ([d343ebb](https://github.com/GuillaumeDerivery/kheona-skill/commit/d343ebb02bcd2e8fd4e30dde26ea8665d764e6fd))

## [2.1.0](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.0.2...v2.1.0) (2026-11-09)


### Features

* the kheona Claude Code skill lives here: SKILL.md, stacks/, enforce.sh ([#21](https://github.com/GuillaumeDerivery/kheona-skill/issues/21)) ([9b0b2e7](https://github.com/GuillaumeDerivery/kheona-skill/commit/9b0b2e71d0f0b33e617d9aca75198383cc3f7641))


### Bug Fixes

* **renovate:** run as the App's own login, so Renovate finds its Dependency Dashboard ([#22](https://github.com/GuillaumeDerivery/kheona-skill/issues/22)) ([3ee97ea](https://github.com/GuillaumeDerivery/kheona-skill/commit/3ee97ea29d48eeee71e8a8925a32fab32f1c1b01))

## [2.0.2](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.0.1...v2.0.2) (2026-11-09)


### Bug Fixes

* **ci:** retry tool downloads; free disk on the Android delivery runner ([#11](https://github.com/GuillaumeDerivery/kheona-skill/issues/11)) ([8556e7e](https://github.com/GuillaumeDerivery/kheona-skill/commit/8556e7e6be7e3c6efa9c3d3dc9997d470237212f))
* **renovate:** run the plan script from this version's files, not the caller's checkout ([#19](https://github.com/GuillaumeDerivery/kheona-skill/issues/19)) ([69da522](https://github.com/GuillaumeDerivery/kheona-skill/commit/69da522a2e1138153e2442fe94b3468ce1ff336b))

## [2.0.1](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.0.0...v2.0.1) (2026-11-09)


### Bug Fixes

* **callers:** a repository with no stack still gets [@claude](https://github.com/claude), the inbox and release-please; a library its forks' notice ([#15](https://github.com/GuillaumeDerivery/kheona-skill/issues/15)) ([96429de](https://github.com/GuillaumeDerivery/kheona-skill/commit/96429deb38d05b8d61e088f3b3fef509b051c7b6))
* **guard:** a squash merge's Co-authored-by trailer for the own App is its identity ([#14](https://github.com/GuillaumeDerivery/kheona-skill/issues/14)) ([70f83eb](https://github.com/GuillaumeDerivery/kheona-skill/commit/70f83ebab0a624fa03e40b56cdb74ce0b272b81e))
* **release-check:** a fork's published release deploys production ([#17](https://github.com/GuillaumeDerivery/kheona-skill/issues/17)) ([25690fd](https://github.com/GuillaumeDerivery/kheona-skill/commit/25690fd800737180bca369daf90c2fb2211f84c7))

## [2.0.0](https://github.com/GuillaumeDerivery/kheona-skill/compare/v1.0.3...v2.0.0) (2026-11-08)


### ⚠ BREAKING CHANGES

* callers must be regenerated at v2. The prod branch and its release PR are no longer used; kskill-deploy.yml takes no environment input.

### Features

* production releases from version tags, merged by a person ([#8](https://github.com/GuillaumeDerivery/kheona-skill/issues/8)) ([f646f8b](https://github.com/GuillaumeDerivery/kheona-skill/commit/f646f8bc11861904598d913a3dc19cd840b43a79))


### Bug Fixes

* kheona-skill's own App is an authorized author; KSKILL_BOT is required everywhere ([#10](https://github.com/GuillaumeDerivery/kheona-skill/issues/10)) ([90385cd](https://github.com/GuillaumeDerivery/kheona-skill/commit/90385cd2f2f75fa90425d8150f7cb406f86aba80))
