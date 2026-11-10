# Changelog

## [2.5.0](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.4.0...v2.5.0) (2026-11-10)


### Features

* Flutter test builds are named after the next patch; a released commit is refused ([#44](https://github.com/GuillaumeDerivery/kheona-skill/issues/44)) ([12c1325](https://github.com/GuillaumeDerivery/kheona-skill/commit/12c13258501b7d6cc562b7046c3de5d7c2664aff))
* production runs the image staging tested; APP_VERSION is set at deploy ([#43](https://github.com/GuillaumeDerivery/kheona-skill/issues/43)) ([ebb1453](https://github.com/GuillaumeDerivery/kheona-skill/commit/ebb1453548628771c76ba01b7d8e1147c5ca03ba))

## [2.4.0](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.3.2...v2.4.0) (2026-11-10)


### Features

* the guard runs locally, as git hooks and a Claude Code hook ([#42](https://github.com/GuillaumeDerivery/kheona-skill/issues/42)) ([1239657](https://github.com/GuillaumeDerivery/kheona-skill/commit/1239657d4460545b9ea65fd53372f7c4daa35909))
* the setup command, the delivery rule, the delivery dry run ([#40](https://github.com/GuillaumeDerivery/kheona-skill/issues/40)) ([869804f](https://github.com/GuillaumeDerivery/kheona-skill/commit/869804fe21650af52efa8a6907f9a56d488469bb))

## [2.3.2](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.3.1...v2.3.2) (2026-11-10)


### Bug Fixes

* the guard reads no account id inside a commit SHA ([#39](https://github.com/GuillaumeDerivery/kheona-skill/issues/39)) ([9e91c19](https://github.com/GuillaumeDerivery/kheona-skill/commit/9e91c1999827acbfd0c902ac1b30e9b814a88d19))
* the token broker's health endpoint is /healthcheck ([#37](https://github.com/GuillaumeDerivery/kheona-skill/issues/37)) ([6a52a65](https://github.com/GuillaumeDerivery/kheona-skill/commit/6a52a65840a15147e4d7e869390658716c10435f))

## [2.3.1](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.3.0...v2.3.1) (2026-11-10)


### Bug Fixes

* Renovate's npm may fetch a direct git dependency ([#35](https://github.com/GuillaumeDerivery/kheona-skill/issues/35)) ([53733f7](https://github.com/GuillaumeDerivery/kheona-skill/commit/53733f7132de3a89f9364d14a8e69645a25abfc3))

## [2.3.0](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.2.2...v2.3.0) (2026-11-10)


### Features

* rule-0 status, conventional PR titles, Renovate reads lib, broker /health ([#33](https://github.com/GuillaumeDerivery/kheona-skill/issues/33)) ([b775a0b](https://github.com/GuillaumeDerivery/kheona-skill/commit/b775a0b914a88e0ef3fcabf0cf27525383d76ce9))

## [2.2.2](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.2.1...v2.2.2) (2026-11-09)


### Bug Fixes

* the Sentry triage asks the broker for its own tokens ([#31](https://github.com/GuillaumeDerivery/kheona-skill/issues/31)) ([e2ff5ed](https://github.com/GuillaumeDerivery/kheona-skill/commit/e2ff5edb81c3348e0db9445e14c0d6f52c723c45))

## [2.2.1](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.2.0...v2.2.1) (2026-11-09)


### Bug Fixes

* the Node gate never skips a push run ([#29](https://github.com/GuillaumeDerivery/kheona-skill/issues/29)) ([d8cecd4](https://github.com/GuillaumeDerivery/kheona-skill/commit/d8cecd4febdbc6feba78d00d05e319459624abaf))

## [2.2.0](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.1.1...v2.2.0) (2026-11-09)


### Features

* the release path tests what it ships ([#27](https://github.com/GuillaumeDerivery/kheona-skill/issues/27)) ([1683119](https://github.com/GuillaumeDerivery/kheona-skill/commit/1683119edee0160186f343c126ecf900e86265f4))

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
