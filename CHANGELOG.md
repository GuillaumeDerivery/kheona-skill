# Changelog

## [2.10.1](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.10.0...v2.10.1) (2026-11-11)


### Bug Fixes

* **inbox:** submodules clone with the library token after the per-owner helper is installed ([#69](https://github.com/GuillaumeDerivery/kheona-skill/issues/69)) ([38df025](https://github.com/GuillaumeDerivery/kheona-skill/commit/38df025671bf2be205688cc21134af772767c986))

## [2.10.0](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.9.0...v2.10.0) (2026-11-11)


### Features

* drop the deprecated delivery secret names ([#72](https://github.com/GuillaumeDerivery/kheona-skill/issues/72)) ([a9ecb40](https://github.com/GuillaumeDerivery/kheona-skill/commit/a9ecb4082ddc9bc815afa0729d1da810c35809b2))

## [2.9.0](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.8.0...v2.9.0) (2026-11-11)


### Features

* **deliver:** the delivery secrets are ANDROID_* and APPLE_*, the old names a deprecated fallback ([#70](https://github.com/GuillaumeDerivery/kheona-skill/issues/70)) ([34cce2b](https://github.com/GuillaumeDerivery/kheona-skill/commit/34cce2bc92d3e2c131e2e5ea92ef9dc738353ca1))

## [2.8.0](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.7.1...v2.8.0) (2026-11-10)


### Features

* **deliver:** the Android signing secrets are ANDROID_*, CM_* a deprecated fallback ([#63](https://github.com/GuillaumeDerivery/kheona-skill/issues/63)) ([1b81332](https://github.com/GuillaumeDerivery/kheona-skill/commit/1b81332fabd3ed968ec1d790b7de898fd3e4146e))
* **deliver:** the self-test's dry run runs each lane up to signing ([#66](https://github.com/GuillaumeDerivery/kheona-skill/issues/66)) ([e081298](https://github.com/GuillaumeDerivery/kheona-skill/commit/e0812988a66a41bd095c5ff00cbccb1d676c9f52))
* **setup:** walk through each secret without reading it, check the App, resume where it stopped ([#64](https://github.com/GuillaumeDerivery/kheona-skill/issues/64)) ([86da0cf](https://github.com/GuillaumeDerivery/kheona-skill/commit/86da0cf306f75de0a2a45154143096261992c44f))


### Bug Fixes

* **deliver-flutter:** accept a distribution .p12 without a password ([#68](https://github.com/GuillaumeDerivery/kheona-skill/issues/68)) ([7139bb8](https://github.com/GuillaumeDerivery/kheona-skill/commit/7139bb8aa2b0cede6b6bd3132b5a44de62b6418b))

## [2.7.1](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.7.0...v2.7.1) (2026-11-10)


### Bug Fixes

* **renovate:** one kheona-skill PR per release, and a warning when the plan runs behind it ([#61](https://github.com/GuillaumeDerivery/kheona-skill/issues/61)) ([a63689f](https://github.com/GuillaumeDerivery/kheona-skill/commit/a63689f9db2d3a04e7808c20e576847ed537f466))

## [2.7.0](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.6.2...v2.7.0) (2026-11-10)


### Features

* one shared workflow per job, the stack read from the repository ([#58](https://github.com/GuillaumeDerivery/kheona-skill/issues/58)) ([64fa007](https://github.com/GuillaumeDerivery/kheona-skill/commit/64fa007a8929f11ca533946206bc07d88fd77cd5))
* two modes for /kheona, the default fixes and files, report only reports ([#60](https://github.com/GuillaumeDerivery/kheona-skill/issues/60)) ([648ecef](https://github.com/GuillaumeDerivery/kheona-skill/commit/648ecef24c1d3c69d533316c9ac7e42b1cbd1818))

## [2.6.2](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.6.1...v2.6.2) (2026-11-10)


### Bug Fixes

* the Claude guard hook checks only what can reach the write ([#53](https://github.com/GuillaumeDerivery/kheona-skill/issues/53)) ([9e46216](https://github.com/GuillaumeDerivery/kheona-skill/commit/9e46216e5c6921a88cda6d08c5c028e61984f3a9))

## [2.6.1](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.6.0...v2.6.1) (2026-11-10)


### Bug Fixes

* Renovate updates lib and kheona-skill themselves again ([#51](https://github.com/GuillaumeDerivery/kheona-skill/issues/51)) ([893c417](https://github.com/GuillaumeDerivery/kheona-skill/commit/893c4177041c0f9d2a5d5270612872aa3e7cd4e9))

## [2.6.0](https://github.com/GuillaumeDerivery/kheona-skill/compare/v2.5.0...v2.6.0) (2026-11-10)


### Features

* **ci-flutter:** check the iOS Swift package pins and resolve them on pull requests ([#46](https://github.com/GuillaumeDerivery/kheona-skill/issues/46)) ([ca07de9](https://github.com/GuillaumeDerivery/kheona-skill/commit/ca07de99b783341d94d925c542bbe7cbabc56b2f))


### Bug Fixes

* Renovate's kheona-skill PR passes CI, in repositories that carry lib too ([#49](https://github.com/GuillaumeDerivery/kheona-skill/issues/49)) ([2c7db2f](https://github.com/GuillaumeDerivery/kheona-skill/commit/2c7db2f32ad6f6403817f53c1276ccee1eff47ea))
* the Claude guard hook checks only commands that write ([#50](https://github.com/GuillaumeDerivery/kheona-skill/issues/50)) ([a17e275](https://github.com/GuillaumeDerivery/kheona-skill/commit/a17e275e1af6d789f5cfbe7d542d3f6cc6eda33b))
* the lib bump leaves lib's git dependencies alone ([#48](https://github.com/GuillaumeDerivery/kheona-skill/issues/48)) ([264d98c](https://github.com/GuillaumeDerivery/kheona-skill/commit/264d98c4d3b521b729eeb2453d93fabfe1a44b54))

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
