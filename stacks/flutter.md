<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# Kheona stack extension — Flutter / Dart

Commands for each `SKILL.md` item, for every Flutter app. The shared workflows are `kskill-ci-flutter.yml` (the
gate), `kskill-main-flutter.yml` (a push to `main`) and `kskill-deliver-flutter.yml` (TestFlight and Google Play from a
version tag).

## K1 — Toolchain

```bash
flutter --version
grep -n "sdk:" pubspec.yaml | head -3
cat .fvmrc .tool-versions 2>/dev/null
grep -n "flutter-version\|channel:" .github/workflows/*.yml   # K1.1: must name a version
cat pubspec.lock >/dev/null && git ls-files --error-unmatch pubspec.lock   # K1.2
```

**K1.3 — the Android triple is derived, not chosen.** Gradle / AGP / Kotlin must equal
`templateDefaultGradleVersion` / `templateAndroidGradlePluginVersion` / `templateKotlinGradlePluginVersion`
in the *installed* SDK's `packages/flutter_tools/lib/src/android/gradle_utils.dart`, with AGP ≤
`maxKnownAndSupportedAgpVersion`. They move as a set (AGP 9 requires Gradle 9.x).

```bash
bash ~/.claude/skills/kheona/.github/scripts/kskill-check-flutter-toolchain.sh   # what the Flutter CI runs
grep -n distributionUrl android/gradle/wrapper/gradle-wrapper.properties
grep -nE "com.android.application|kotlin.android" android/settings.gradle.kts
grep -nE "compileSdk|minSdk|targetSdk|ndkVersion" android/app/build.gradle.kts  # should read flutter.*
```

Also check `targetSdk` against Play's current target-API requirement for *new releases* — Play enforces a
hard deadline each year and rejects uploads below it.

**iOS — CocoaPods must not be used. Swift Package Manager only.**
```bash
ls ios/Podfile ios/Podfile.lock 2>/dev/null                              # must print nothing
ls -d ios/Pods 2>/dev/null                                               # must print nothing
ls -d ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage  # must exist
grep -rn "pod install\|cocoapods\|Podfile" .github/workflows/ ios/fastlane/ 2>/dev/null  # nothing
grep -rn "IPHONEOS_DEPLOYMENT_TARGET" ios/Runner.xcodeproj/project.pbxproj | sort -u
grep -n "xcode\|macos-" .github/workflows/*.yml   # pin the image, not macos-latest
```
**Pass:** no `Podfile`, no `Podfile.lock`, no `ios/Pods/`, no `pod install` anywhere in CI or fastlane,
and the generated Swift package present. A repo carrying *both* a Podfile and
`ios/Flutter/ephemeral/Packages` is on the hybrid path — that is a FAIL, not a partial pass: it still has
every CocoaPods failure mode below while looking migrated.

**Why the ban:** CocoaPods resolves at build time against a remote spec repo, so a build is not
reproducible from the checkout alone. It is a second package manager — its own Ruby toolchain, its own
version, its own lockfile — sitting beside pub's, and a `pod install` rewrites `project.pbxproj` every
time, which makes project-file diffs unreadable and merge conflicts routine. With `platform :ios` unset
it silently applies its own deployment target, usually *lower* than the app's, to every pod. It is also
in maintenance mode upstream. SPM removes the layer entirely: Xcode resolves plugins itself, from the
versions `pubspec.lock` already pins.

**Migrating a repo off it:** `flutter config --enable-swift-package-manager`, confirm every plugin the
app uses ships a Swift package, then delete `ios/Podfile`, `ios/Podfile.lock` and `ios/Pods/`, strip the
CocoaPods build phases from `project.pbxproj`, remove `pod install` from CI and fastlane, and rebuild
clean. A plugin with no Swift package blocks the migration — name it rather than reintroducing the
Podfile for it.

**K1.4 — currency first; the bot is the last topic, not the first.**

**1 — Direct dependencies.**
```bash
flutter pub outdated
```
Read the `direct dependencies:` table. Nothing more than one major behind without a tracking issue.

**2 — Then read the summary line at the BOTTOM of that same output.** It is easy to miss, and it is a
finding on its own:
```
52 upgradable dependencies are locked (in pubspec.lock) to older versions.
To update these dependencies, use `flutter pub upgrade`.
```
That count is mostly *transitive* packages, and it can be large while the direct-deps table shows one
entry or none at all. Piping this command through `| head`, or reading only the direct-deps block, is
precisely how a repo gets audited as "dependency drift is small" while fifty packages sit behind.

If the number is non-zero: `flutter pub upgrade` moves them **within the existing `pubspec.yaml`
constraints**, so it cannot break an API by construction, and the K2.1 gate verifies it. That makes it a
cheap, low-risk PR — there is no excuse for carrying the backlog.
`flutter pub upgrade --major-versions` is the separate, riskier operation: it rewrites `pubspec.yaml`.

> **This only becomes a standing concern once K1.2 is satisfied.** With no committed lockfile,
> transitives re-resolve on every install — invisible, but self-correcting. With one, they are frozen
> until a human runs the upgrade. **A repo that just committed its lockfile has, in the same stroke,
> acquired this obligation.** See SKILL.md K1.4.

**3 — Only now, the automation.**
```bash
cat renovate.json                       # extends github>owner/kheona-skill//renovate/default#vX.Y.Z
gh pr list --search "head:renovate/"    # Renovate's open PRs
```
Renovate (SKILL.md K1.4) covers `pub` and `github-actions`, and closes item 2 with weekly `lockFileMaintenance`
of every `pubspec.lock` (the root's and each local package's), which version updates never reach. The Kheona
preset leaves Gradle, the Gradle wrapper, AGP, Kotlin and the Flutter/Dart SDK alone: K1.3 and the inbox's
refresh-flutter job own them.

**K1.5 — run the routine, don't eyeball it:**
```bash
bash ~/.claude/skills/kheona/scripts/kskill-versions.sh   # project + machine + upstream, with fix commands
```
It resolves the Flutter pin whether it sits on a `flutter-version:` line or as a composite action's
`default:`, reads `compileSdk`/`targetSdk` from `build.gradle` or `build.gradle.kts` and reports
`flutter.*` as *correct* rather than unresolved, and flags `channel: stable` as a K1.1 failure rather
than silently passing it. Manual equivalents:
```bash
flutter --version                       # installed + channel
curl -s https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json \
  | jq -r ".releases | map(select(.channel==\\"stable\\")) | .[0] | \\"latest stable: \\(.version)  released \\(.release_date[0:10])\\""
```
Flutter ships a stable roughly every quarter and supports a narrow window. Compare, then record: current,
one behind deliberately, or overdue with an issue.
**In CI: the refresh-flutter job of `kskill-inbox.yml` (K2.10, every Flutter repository)** opens `chore/refresh-flutter-sdk` monthly
when the feed's latest stable is newer than the pin: `.fvmrc` moved, `flutter pub get`, analyze and test, with
the toolchain check, the SDK's old vs new defaults and this `kskill-versions.sh` report in the body, and the
Android triple as a checklist (K1.3: never applied for you). A person merges it; it is never auto-merged. Also check Xcode/macOS runner image currency and
Android `targetSdk` against Play's deadline for *new releases* (§K1.3 above) — three separate clocks.

## K2 — Pipeline

*The shared workflows build, sign and deliver; auditing is mostly checking the callers are current
(`node ~/.claude/skills/kheona/scripts/kskill-callers.mjs check --repo .`).*

```bash
ls .github/workflows/
grep -nE "^  [a-z_-]+:$|runs-on|needs:|if:|timeout-minutes|permissions" .github/workflows/*.yml
gh secret list
gh api repos/:owner/:repo/rulesets                       # K2.1: is the gate actually required?
```

Flutter-specific K2.3/K2.4 notes:
- Android keystore (base64 secret) + store password + key alias + key password. Keystores don't expire,
  but **losing one is unrecoverable** — confirm an off-machine backup exists.
- iOS: an Apple Distribution certificate imported per run + a profile fetched from App Store Connect.
  **Certificates expire yearly and Apple caps you at 3 active** — record the expiry somewhere visible.
- App Store Connect API key **role** matters: App Manager fetches an existing profile; Xcode cloud
  signing (`-allowProvisioningUpdates`) needs Admin.
- Pin fastlane to an exact version. An unpinned `gem install fastlane` is how a working `sigh(type:)`
  call starts failing overnight.
- K2.3 build numbers: `git rev-list --count HEAD` (`.github/scripts/kskill-build-number.sh`, plus
  `.kheona.json`'s offset) — **not** what is live on the store. Both stores' lookups lag what their upload endpoint
  enforces, and reading each store separately drifts the two platforms apart, so "build 39" stops meaning one
  commit. Nothing is committed back to git, the version *name* comes from `pubspec.yaml` only, and the checkout is
  full: at depth 1 the count is `1`, which every store rejects. `BUILD_NUMBER_OVERRIDE` re-ships an unchanged commit
  once.
- **K2.8 is at its sharpest here.** Both stores consume a version number permanently, Apple caps uploads
  per app per day (`90382`), and the macOS lane bills at 10x. The stores get a build only from a version tag (a
  person merging the release PR); a dispatch on `main` is a test build. `gh run list --workflow kskill-deliver.yml`
  is where a release lives.
- K2.6: print `<versionName> (<buildNumber>)` to `$GITHUB_STEP_SUMMARY`, and read iOS's back out of the
  built `.ipa`.

**K2.7 — both stores, from CI, signed.**
```bash
grep -nE "upload_to_testflight|pilot|deliver|upload_to_play_store|supply" ios/fastlane/Fastfile android/fastlane/Fastfile 2>/dev/null
grep -nE "aab|ipa|bundleRelease|build appbundle|build ipa" .github/workflows/*.yml
gh run list --workflow kskill-deliver.yml --limit 5 --json conclusion,headBranch,createdAt   # did the last tags reach the stores?
```
**Pass:** the Android job builds a **signed `.aab`** and uploads to Play's internal testing track; the iOS
job builds a **signed `.ipa`** and uploads to TestFlight; both `needs:` the analyze/test gate; both live
in the delivery a version tag starts (K2.8), so they are unreachable from a pull request and from a merge
to `main` alike. A debug APK left as a workflow artifact is not a publish step.

## K3 — Code health

```bash
flutter analyze                                          # K3.2, must be empty
dart format --output=none --set-exit-if-changed lib/     # K3.1, must exit 0
cat analysis_options.yaml                                # flutter_lints in; build/ android/ ios/ excluded
git status --short                                       # K3.8
```

**K3.3 — the design system exists and covers the categories.** Settle it by listing it, not by asking.
```bash
ls lib/core/theme/ lib/core/widgets/          # or this repo's equivalent — tokens and shared components
```
**Pass:** one directory owns the tokens — colour, typography, spacing, radius, elevation/shadow, motion
— and one owns the shared components built from them. Typical Flutter shape: an `AppColors`, a
`ThemeData`/`TextTheme` carrying every text rung, an `AppShadows`, and shared widgets for button, text
field, dropdown, dialog, sheet, list row, empty state and skeleton. **A `ThemeData` alone is not a pass**
— Material's theme styles the raw widgets, it does not give a screen a component to reach for, which is
why a themed app still ends up with a bespoke button per screen.

**K3.4/K3.5 — reuse, and register what is new.** Neither is a single grep; both are settled by reading
the diff of the work being audited against the component index.
```bash
git diff --name-only main... | grep '^lib/features/'   # new widgets in feature folders are the suspects
grep -rn "class _\?[A-Z][A-Za-z]*\(Button\|Field\|Card\|Sheet\|Dialog\|Row\|Chip\|Badge\)" \
  lib/features/ --include="*.dart"
```
**Pass:** every hit is genuinely single-use for that screen. A private `_ActionPill` used by one screen
is fine; a second screen wanting one means it moves to `lib/core/widgets/` first. Anything that did move
there is listed in the repo's design-system catalogue screen **and** its `CLAUDE.md` — check both, since
the catalogue is the one a future screen actually reads.

**K3.6 — design-system invariants.** Each of these should return nothing. The filenames after `grep -v`
are **this repo's** design-system files: they belong in `.kheona.json`'s `designSystem.allow`, which is
what `enforce.sh` reads, so the same rules run unchanged in a repo that names its files differently.
```bash
grep -rnE "(^|[^A-Za-z])(ElevatedButton|TextButton)\(" lib/ --include="*.dart" | grep -v app_buttons.dart
grep -rn "DropdownButtonFormField(" lib/ | grep -v app_dropdown_field.dart
grep -rn "AlertDialog(" lib/ | grep -v app_dialog.dart
grep -rnE "(^|[^A-Za-z])Colors\.(black|white)" lib/ --include="*.dart" | grep -vE "core/(theme|widgets)/|webview"
grep -rn "BoxShadow(" lib/ --include="*.dart" | grep -v "app_shadows\|core/widgets/"
```
**The colour rule needs the `(^|[^A-Za-z])` guard, and this is not cosmetic.** `Colors\.(black|white)`
also matches **`AppColors.white`** — the token — so the unguarded form flags every file that uses colour
*correctly*. Measured on one app: 49 files flagged unguarded, **11 guarded**, and all 11 are the
documented exceptions (the `.light` shared-widget variants, the two WebView hosts, and the dialog's and
snackbar's own drop shadows) — i.e. green. A check whose hits are almost all false is
one whose output people stop reading, which costs more than not having it.

The shadow rule is the one most often missing: elevation is the token people re-type by hand, because a
`BoxShadow` looks like styling rather than like a decision. On that same app its only three hits were
inside `core/widgets/`, i.e. inside the system itself.

**What is deliberately *not* an invariant here**, because it is red everywhere and a permanently-red
check is one people learn to ignore: raw `TextStyle(` (163 hits on that app, nearly all
legitimate `textTheme.x.copyWith`), literal `fontSize:` (134), and `Color(0x…)` (40 — the glass
recipes). Typography and inline colour are audited by reading the diff, not by grep. Do not add them to
`.kheona.json` on a repo where they cannot be green today.

**Localization** (repos using slang):
```bash
grep -rnE "Text\((['\"])" lib --include="*.dart" | grep -v "lib/l10n/"
dart run slang && git diff --exit-code lib/l10n/strings.g.dart
```

**K3.9 — business rule values.** Not fully grep-able — read the diff for raw numbers in conditions,
and confirm each rule has a named home:
```bash
grep -rnE "(>=|<=|>|<|==)\s*[0-9]+(\.[0-9]+)?\b" lib/features --include="*.dart" | grep -v "\.g\.dart"
cat lib/core/constants/app_constants.dart
```
**Pass:** every hit is structural (`index == 0`, `length > 0`), never a rule (`score >= 0.8`, `count >= 3`).

### App configuration constants

One shape for every Flutter app. **Everything an app is
configured with is a `static const` on `abstract final class AppConfig` in `lib/core/config/app_config.dart`**,
compiled in and committed: endpoints, tenant / program ids, public client ids and keys (an identity provider's public client, a
Mapbox `pk.` token, an Intercom app id) and the error tracker's configuration. Nothing here is a secret: it ships
inside the binary either way.

- **No runtime `.env`.** No `flutter_dotenv`, no bundled `.env` asset: a constant cannot go missing at runtime.
  The `.gitignore` still has `.env`, `.env.*` and `!.env.example` (SKILL.md K5.1; the repository check's check 7), for a
  repository tool that reads one; no `.env.example` is needed for the app.
  A "required, non-empty" guarantee becomes a unit test over the constants, not a runtime `StateError`.
- **Sentry (K8.4): no separate `sentry_config.dart`.** `AppConfig.sentryDsn` is the committed DSN (a Flutter
  app's DSN may be committed, SKILL.md K8.4; empty means off, which is what a fork without a Sentry project
  sets). The one build-time value is the environment:
  ```dart
  static const String sentryEnvironment =
      String.fromEnvironment('SENTRY_ENVIRONMENT', defaultValue: 'prod');
  ```
  `kskill-deliver-flutter.yml` passes `SENTRY_ENVIRONMENT` to each fastlane lane from
  `workflows.cd.android.sentryEnvironment` / `workflows.cd.ios.sentryEnvironment` (`staging` by default:
  TestFlight / Play internal; `prod` for a lane that ships to the store), and the lane compiles it in with
  `--dart-define=SENTRY_ENVIRONMENT=$SENTRY_ENVIRONMENT`. The `kReleaseMode` gate stays: a debug or simulator build
  reports nothing whatever the environment says. The *behaviour* (`isExpectedSentryError`, scrubbing, the seam)
  is not configuration and stays in `lib/core/observability/`.
- **Crashlytics (Firebase) is configured the same way.** App-level flags (collection enabled, and the like) are
  `AppConfig` constants; the FlutterFire-generated options live at `lib/core/config/firebase_options.dart`,
  regenerated in place with `flutterfire configure --out=lib/core/config/firebase_options.dart`; the environment is
  `AppConfig.crashlyticsEnvironment` from the same `SENTRY_ENVIRONMENT` define (the deliver lanes pass one name for
  either tracker), set at start with `FirebaseCrashlytics.instance.setCustomKey('environment', ...)`.
- **Design constants are not configuration.** Colours, text styles, gradients, shadows stay in the design system
  (K3.3); business rules stay in `lib/core/constants/app_constants.dart` (K3.9). `config/` is what changes when
  the app is pointed at another tenant or deployment, nothing else.
- **Enforced:** `enforce.sh`'s fast tier and the repository check (check 6, a warning, `config` in `--json`) flag
  `String.fromEnvironment`, `bool.fromEnvironment`, `int.fromEnvironment` or `dotenv` in any `lib/` file outside
  `lib/core/config/`. No `.kheona.json` entry is needed: the location is fixed.
```bash
grep -rnE "(String|bool|int)\.fromEnvironment\(|dotenv" lib/ --include="*.dart" | grep -v "^lib/core/config/"   # must print nothing
grep -n "flutter_dotenv\|- \.env" pubspec.yaml                                                                 # must print nothing
grep -n "dart-define=SENTRY_ENVIRONMENT" android/fastlane/Fastfile ios/fastlane/Fastfile
```

**K3.10 — user-facing strings:**
```bash
grep -rnE "== 'fr'|isFr *\?" lib --include="*.dart" | grep -vE "\.g\.dart|/domain/|lib/features/debug/"
```
**Pass:** empty. Excluded on purpose: `domain/` models picking between the `…EN`/`…FR` fields of a
**remote bilingual feed** (`titleForLocale(languageCode)`) — that is content, not copy. Locale-picked
asset paths (videos, localized images) are copy: they go in the translation files as keys, so the
locale is chosen in exactly one place.

**K3.7 — unused assets:**
```bash
for f in $(find assets/images -name "*.png" ! -path "*[23].0x*" -exec basename {} \;); do
  grep -rq "$f" lib/ pubspec.yaml || echo "UNUSED: $f"
done
```

## K4 — Tests and coverage

`lcov` is a prerequisite and is **not** installed by default on macOS — `brew install lcov`. A missing
`lcov` is why the filter step gets skipped, and an unfiltered number then gets reported as if it meant
something.

```bash
ls test/                                    # must not be empty, and not just widget_test.dart
flutter test --coverage
lcov --remove coverage/lcov.info \
  '*/l10n/*' '*/gen/*' '*.g.dart' '*.freezed.dart' '*.mocks.dart' '*/generated_plugin_registrant.dart' \
  -o coverage/filtered.info --ignore-errors unused,empty
lcov --summary coverage/filtered.info
```

**Filter to a SEPARATE file — never `-o` back onto the input.** In-place filtering silently no-ops on
lcov 2.x (Homebrew ships 2.5) *while still printing "Removed N files"*, so the summary is then taken
over the unfiltered report. It reads as a plausible-but-wrong number rather than as an error: on
one app it reported 2.1 % of 4999 lines where the truth was 7.2 % of 1411. If a repo's local and CI
coverage disagree, this is the first thing to check.

Generated code lands in `lib/l10n/` or `lib/gen/` depending on the repo's slang config — filter both.

**Reading the percentage back out:** anchor on the `%`, e.g.
`sed -n 's/.*lines\.*: *\([0-9][0-9.]*\)%.*/\1/p'`. Do **not** use `grep -oE 'lines\.*: *[0-9.]+'`
piped into `grep -oE '[0-9.]+'` — `[0-9.]` also matches the run of dots in `lines.......:`, so the first
match is `.......` and every numeric comparison downstream dies with an awk syntax error that a `&&`
chain will swallow silently.

The filter is not optional: `flutter test --coverage` counts generated files, and `strings.g.dart` alone
is thousands of lines. Unfiltered, the percentage moves for reasons unrelated to the tests.

**Do not assume a codegen pragma has already handled this.** slang writes `// coverage:ignore-file` into
`strings.g.dart`, so on some repos generated code never enters the report and filtering appears to be a
no-op — but `json_serializable`, `riverpod` and `drift` output carries no such pragma. Check rather than
generalise from one repo: `grep -c '^SF:' coverage/lcov.info` before and after the filter. On that app
that is 5012 lines raw against 1424 filtered; on a neighbouring repo it was byte-identical.

**K4.2 — Flutter has no coverage target, and a number off `flutter test --coverage` is wrong.**

`flutter test --coverage` only instruments libraries a test **transitively imports**. A file nothing
imports is *absent* from the report, not present at 0 %, so the denominator shrinks to the part of the
app already under test. Measured on one app: the vanilla report covered 37 of 158
libraries and read **10.9 %**, against a real **2.6 %** across the whole app — inflated ~4x. It gets
worse as the app grows untested, and can *fall* when a good test drags untested dependencies in.

It can be made honest with a generated test that imports every library. **That was tried and
removed.** It is a generated file to keep in sync plus a CI step to guard it, it went
stale twice on the day it landed, and it only ever served a threshold. Once the threshold went, it
bought nothing. **Do not reintroduce it, and do not build an equivalent.** Vanilla commands only.

So, for Flutter:

> **There is no 90 % target, and no coverage percentage is quoted — not in a `CLAUDE.md`, not in a PR,
> not in an issue, not in an audit report.**

This is a deliberate exception to K4.2's ≥ 90 %, taken because **a standard cannot demand a
number the toolchain will not produce honestly.** Enforcing a floor over a denominator known to be
wrong is the exact failure K4.2 warns about, and the same reasoning applied to the target itself.

**Reporting a Flutter coverage percentage is a FAIL, not a pass.** Quoting the vanilla number is worse
than quoting none: it reads like a measurement and propagates into documentation as fact. If an audit
wants a coverage finding, name **what is covered and what is not** — `flutter test --coverage`'s
**per-file** output is correct even when its total is not, so "`provider_auth_service.dart` is at 0 %" is
a legitimate, checkable finding and "the app is at 10.9 %" is not.

What K4 still requires here, in full:
- **K4.1** a real suite that passes;
- **K4.5** the expensive logic first — money arithmetic and rounding, validators, token-expiry and
  refresh decisions, API↔domain mappers, notifiers over a faked repository;
- **K4.6** deterministic: no sleeps, no real network, no shared mutable fixtures, no order dependence.

Progress is tracked by *what* is covered, on an issue, not by a percentage on a dashboard.

Pure-Dart packages are **not** covered by this exception — see K4.3.

In the K4 bootstrap phase (`.kheona.json` `"phase": "bootstrap"`, SKILL.md K4) an app with no `test/` directory
passes, and a package's `failUnder` is reported, not enforced.

**K4.3 — the CI gate. For Flutter, CI collects coverage and publishes it, but gates on nothing.**

```yaml
- run: flutter test --coverage
- uses: actions/upload-artifact@v7
  if: always()                      # a failing suite is when you most want the report
  with:
    name: coverage-lcov
    path: coverage/lcov.info
```

No `lcov`, no threshold action, no percentage parsed, no generated helper and no staleness step. The
gate is lockfile install → toolchain check → format → analyze → test; `--coverage` is collected for the
artifact only and never decides whether the run passes.

**Why collect it at all if nothing gates on it:** the *per-file* report is correct even though the total
is not (K4.2), and a file absent from `lcov.info` is a file no test imports — so the artifact answers
"what is untested" directly, as a list of filenames, which is the form K4 actually tracks progress in.
Downloading it and diffing its `SF:` records against `find lib -name '*.dart'` needs no committed
script and nothing kept in sync. **Do not turn that diff into a CI step, a percentage or a floor** —
that is precisely what was removed, and the artifact exists so nobody needs to rebuild it.

The tooling facts behind gating on nothing, each measured rather than assumed: `lcov` is not on
GitHub's runners and costs ~20 s of `apt-get` per run, more than `flutter test` itself on a small suite; `lcov` 2.x silently
no-ops an in-place `--remove` while still reporting that it removed files, so a dev Mac and the runner
can disagree about the same commit; and `flutter test` prints no percentage and has no threshold flag,
so enforcing one means carrying a shell parser (one app carried 91 lines of it, ~40 of them a
generated-file filter measured to remove **zero** files).

**Pure-Dart packages are different and do get a threshold.** `dart test` is not subject to the Flutter
plugin's instrumentation behaviour in the same way, and
[`package:coverage`](https://pub.dev/packages/coverage) has a real built-in threshold — verified, exit 1
below and 0 above:

```bash
dart run coverage:test_with_coverage --fail-under=90
# Error: Coverage 33.33% is less than required 90.00%   -> exit 1
```

Use it for `packages/*` and for any non-Flutter Dart repo. Note it does **not** fix the denominator
either — an unimported library is absent from its report too — so treat its number the same way: a
threshold over code the tests reach, not a claim about the whole package.

**K4.5 — what to cover first in a Flutter fintech app:** amount/money formatting and rounding,
IBAN/BIC and form validators, token-expiry and refresh decisions, JSON↔domain mappers, and Riverpod
notifiers driven by a faked repository (`mocktail`).

## K5 — Secrets and privacy

```bash
git log --all --oneline -S"BEGIN PRIVATE KEY" | head
grep -rn "print(\|debugPrint(" lib/ | grep -iE "token|password|pan|cvv|secret"
grep -rn "kDebugMode" lib/core/utils/log_redaction.dart
```

**K5.3 — audit the MERGED manifest, not the source one:**
```bash
grep -n "uses-permission" android/app/src/main/AndroidManifest.xml
find build/app/intermediates/merged_manifest/release -name AndroidManifest.xml \
  -exec grep -n "uses-permission" {} \;
grep -nE "UsageDescription" ios/Runner/Info.plist
find ios/Runner -name "PrivacyInfo.xcprivacy"
```
A networked Flutter app frequently has no `INTERNET` line of its own — it arrives from a dependency,
which means a dependency change can remove it. Plugins also drag in `READ_EXTERNAL_STORAGE`,
`POST_NOTIFICATIONS` and `WAKE_LOCK`, each of which is a Play data-safety answer you must defend.

The app target's `PrivacyInfo.xcprivacy` is **yours to write** — pods ship their own. `UserDefaults`,
file timestamps and disk space are required-reason APIs, so `shared_preferences`, `path_provider` and
`flutter_secure_storage` all trigger it. TestFlight is more forgiving than App Store review, so a missing
one passes CI for months and then blocks a submission.

**K5.7 — the app's User-Agent**: set on every Dio client the app builds (one helper, used by each
`BaseOptions(headers: {'User-Agent': clientUserAgent()})`), from `package_info_plus` (version, build number) and the
platform: `Acme-Android/2.4.0 (build 412; Android 15)`, `Acme-iOS/2.4.0 (build 412; iOS 18.1)`. Dart's
default is `Dart/3.x (dart:io)` on both platforms, so without it the two apps are one client in every log. A
WebView keeps the system's own user agent.
```bash
grep -rn "BaseOptions(" lib/ | wc -l          # every one of them…
grep -rln "User-Agent\|userAgent" lib/       # …goes through the helper
```

## K6 / K7 — no stack-specific commands

Review and tracker hygiene (K6) and documentation currency (K7) are identical for every stack. Apply
`SKILL.md`'s criteria directly — `gh pr list`, `gh issue list`, `git log --oneline origin/main..HEAD`, a
code-review pass on the branch, and a read of the repo's own `CLAUDE.md`/README against the code as it
is now. K6.3 has one command everywhere: `/code-review` on the full branch. **None of this is optional here just because this file carries no stack-specific commands for it.**

## K8 — Release readiness

```bash
grep -n "PRODUCT_BUNDLE_IDENTIFIER" ios/Runner.xcodeproj/project.pbxproj | sort -u
grep -n "applicationId" android/app/build.gradle.kts
grep -n "^version:" pubspec.yaml
flutter build ios --debug --simulator
flutter build apk --debug
```

Bundle ID and application ID must match each other and the live store records; display name identical in
`Info.plist`, `AndroidManifest.xml`, `MaterialApp.title` and the l10n `appName` key; icons and splash
generated for every density; the OAuth redirect scheme declared identically on both platforms.

**K8.3 is the automated bar only** — both build, and the app launches without crashing. The interactive
pass is the human's and must not be claimed otherwise. **Never verify by screenshot.** Post the VM
Service URI in chat the moment `flutter run` prints it: it is unique per run and unrecoverable
afterwards.

### K8.4 — Sentry: the context that makes a crash report useful, then the symbols

```bash
grep -nE "sentry_flutter|sentry_dart_plugin" pubspec.yaml     # runtime dep + dev dep
grep -n "SentryFlutter.init\|useSink" lib/main.dart
grep -n "^sentry:" -A8 pubspec.yaml                           # org / project / upload_sources
grep -rn "sentry_dart_plugin" .github/workflows/              # runs in the PUBLISH lane, per release
```

Two packages, and the second is the one that gets forgotten:
`sentry_flutter` (runtime, catches) and `sentry_dart_plugin` (dev, uploads debug files).

**Initialise only when `kReleaseMode` is true** (SKILL.md K8.4). In debug and profile,
`runApp` runs directly and every `Sentry.*` call is a no-op on the uninitialised hub. The iOS
simulator cannot run a release build, so `kReleaseMode` excludes it by construction; an Android
emulator *can* — a release build on an emulator is the one case the flag lets through, deliberately.
```bash
grep -rn "kReleaseMode" lib/ | grep -i sentry      # must hit the init gate
```
Verify the integration on a release build (TestFlight / Play internal), never from a debug button.

**The DSN may be committed** (SKILL.md K8.4): `AppConfig.sentryDsn` in
`lib/core/config/app_config.dart` is a compile-time constant (App configuration constants, above; there is no
separate `sentry_config.dart`). A DSN is a public, send-only key and is compiled into the binary anyway, so
committing it is fine for an app (backends are different: their DSN comes only from the deployment's Secret, never committed, K8.4). One Sentry
project per app; the environment is still passed at init (`options.environment = AppConfig.sentryEnvironment`),
`staging` for TestFlight / Play internal, `prod` for the store release, from the lane's
`--dart-define=SENTRY_ENVIRONMENT=...`.
```bash
grep -n "sentryDsn\|sentryEnvironment" lib/core/config/app_config.dart  # the one place both live
grep -rn "environment" lib/core/observability/sentry_service.dart # passed at init
```

**Symbols are the smallest lever here, and this section used to imply otherwise.** With default build
settings the Dart frames are already readable, so symbol upload only ever improves the *native*
minority. What a stack trace cannot supply is what the user was doing — and that is usually missing
entirely. Wire these three before spending time on symbols:

| | Gives an event |
|---|---|
| `SentryNavigatorObserver` in the router's `observers` | which screen, and the route path to it |
| `dio.addSentry()` / `SentryHttpClient` on every HTTP client | the last calls: method, sanitised URL, status |
| `Sentry.configureScope` — opaque user id + 2–3 low-cardinality tags | who, and in what account state |

Two defaults to override, both learned the hard way:
- **`captureFailedRequests: false`.** It defaults to `true` and files every 4xx/5xx as its own
  *event*. Any app that treats a 401 as routine — anything with a refresh-and-retry interceptor —
  opens an issue for the ordinary token-expiry path on every user, every few minutes.
- **`enableAutoTransactions: false`** on the navigator observer unless tracing is actually on. That
  flag is performance monitoring, not breadcrumbs, and starts transactions only to discard them.

**Switching on HTTP breadcrumbs can leak what URL scrubbing already removes.** `Breadcrumb.http`
writes the query string and fragment as their own `data` keys (`http.query`, `http.fragment`) *as
well as* inside `url`, so a `beforeBreadcrumb` that sanitises `url` alone puts them straight back
under a different name. Drop both keys. This matters wherever a query string carries credentials —
an OAuth `code`, a presigned-S3 URL — which is most apps.

**No email, no name, no IP in the scope**, whatever the SDK offers. `sendDefaultPii = false` covers
the IP; the rest is a choice you make once and then defend. Send opaque server-side ids only, and
pin their absence with a test so adding one later fails a run rather than passing a review.

**Wire the SDK's own capture, not a hand-rolled net.** `SentryFlutter.init(options, appRunner: ...)`
installs `FlutterError.onError`, `PlatformDispatcher.onError` and the zone guard itself. If the repo
already owns an error seam (a `lib/core/error_reporting.dart`, say), point that seam's sink at `Sentry.captureException` rather than
replacing it: the SDK then catches everything nobody wrapped, and the seam keeps routing the failures
the app *did* catch and recover from.

**The obfuscation decision comes before the symbol decision, and the usual instinct is backwards.**

> With default settings, complete Dart stack traces are available out of the box. `--obfuscate` and
> `--split-debug-info` are what *make* them unreadable.

So do not reach for those flags in the name of better crash reports — they are an app-size and
IP-protection trade, and they create the problem symbol upload exists to solve. Turn them on only
after an upload has been verified against a real event, never in the same change.

```bash
# Readable by default. This is the right build for a repo whose upload is not yet proven.
flutter build appbundle --release --build-number=N

# Only once upload is proven. --obfuscate REQUIRES --split-debug-info, and the
# extra-gen-snapshot-options map is what keeps the *issue titles* readable too.
flutter build appbundle --release \
  --obfuscate --split-debug-info=build/symbols \
  --extra-gen-snapshot-options=--save-obfuscation-map=build/app/obfuscation.map.json
```

**Upload the debug files regardless of that choice.** Even with readable Dart frames, the *native*
frames — the engine, iOS system libraries — are hex addresses until the dSYMs land.
`upload_debug_symbols` defaults to `true`.

**Leave `upload_sources` off on mobile, and not for the reason it looks like.** It is not "source
context that starts working once you add `--split-debug-info`" — on iOS and Android it never gives
Dart source context at all. The option is the renamed `include_native_sources` (sentry-dart-plugin
#78), and that is exactly what it still does: it passes `--include-sources` to `debug-files upload`,
which bundles the sources of the **native** compilation units being uploaded — the engine's C++, the
ObjC/Swift shell. Your Dart is not among them. The plugin's `.dart`-source upload lives only in its
**sourcemap** path, which is Flutter *web* (#247: "Enable `upload_sources` to opt in to Flutter web
source context").

The deeper reason it cannot work on mobile: a Dart stack trace is produced by the Dart runtime and
arrives in the event already carrying `package:` URIs. It never passes through Sentry's debug-file
symbolication, so there is no debug file for a source bundle to attach to. Setting it `true` uploads
someone else's sources and buys nothing.

Verify rather than trust this paragraph — it is two greps in the installed package:
```bash
grep -n "include_native_sources\|web source context" \
  ~/.pub-cache/hosted/pub.dev/sentry_dart_plugin-*/CHANGELOG.md
grep -n "uploadSources" ~/.pub-cache/hosted/pub.dev/sentry_dart_plugin-*/lib/sentry_dart_plugin.dart
```

```yaml
# pubspec.yaml — auth token from the environment, never committed
sentry:
  upload_debug_symbols: true
  upload_sources: false      # mobile: native sources only, never your Dart. Web: true.
```
```bash
# In the publish lane, immediately after the build, in the SAME job:
#   SENTRY_ORG / SENTRY_PROJECT / SENTRY_AUTH_TOKEN come from secrets.
dart run sentry_dart_plugin
```

**It must run on every release, in the job that built the artifact.** Symbols are per-build: a release
whose symbols were never uploaded is permanently unreadable, and the build output the plugin needs is
gone the moment that job ends.

R8/ProGuard mapping upload (the Sentry *Android Gradle* plugin) is a **third** package and is only
needed when `minifyEnabled` is on. Check before adding it — without minification, JVM frames are
already readable and it buys nothing:
```bash
grep -rn "minifyEnabled\|isMinifyEnabled" android/app/build.gradle*   # nothing => skip the Gradle plugin
```

**K5.2 outlives the SDK's defaults.** Sentry attaches request URLs and breadcrumbs automatically. In a
repo whose rule is "endpoint and status, never the response body", say so in `options` rather than
assuming the defaults respect a policy they cannot see.

**Pass:** both packages present; capture wired in `main()`; `dart run sentry_dart_plugin` in the publish
lane after the build; and a deliberate throw in a **release** build seen arriving with a readable stack.
Verified in debug only is a FAIL — debug is where it works by accident.
