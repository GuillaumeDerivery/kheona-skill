// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
// not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// After submodules/lib moved to a new version (the inbox's bump-lib job, kskill-inbox.yml), makes this project's lockfile resolve every package
// lib declares at the exact version lib's lockfile resolves, so kskill-check-lib-versions.mjs passes
// (submodules/lib/CLAUDE.md, "Rules for any project consuming this library", rule 1).
// - A package this project declares too: installed at lib's exact version (saved exact, so a lock file refresh
//   cannot move it within a range), in the section it already has.
// - A package only lib declares (it reaches this project through lib, e.g. an SDK lib uses): pinned with an
//   npm `overrides` entry, kept in sync with lib on every bump. Without it npm resolves lib's semver range to
//   whatever is newest on the registry, which drifts from lib's own lockfile one patch at a time.
// - A devDependency only lib declares: npm installs a `file:` directory dependency's devDependencies too, so it
//   lands in this project's lockfile and drifts the same way (knip 6.43.0 against lib's 6.42.1 failed the lib
//   3.3.0 bump). Pinned by an `overrides` entry scoped to lib's package, so a project dependency that wants
//   another major of the same tool (globals, eslint...) keeps its own copy.
// - A package lib takes from git, a URL or a path (kheona-skill's shared configs: `github:owner/kheona-skill#<sha>`)
//   has no registry version to align on: left alone, the project keeps its own reference (Renovate moves it).
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const LIB = 'submodules/lib';

const readJson = (path) => JSON.parse(readFileSync(path, 'utf8'));

const manifest = readJson('package.json');
const libManifest = readJson(join(LIB, 'package.json'));
const libLock = readJson(join(LIB, 'package-lock.json')).packages ?? {};
const libSpecs = { ...libManifest.peerDependencies, ...libManifest.devDependencies, ...libManifest.dependencies };
const fromRegistry = (spec) => !/^(git[+:]|github:|gitlab:|bitbucket:|https?:|file:|link:|workspace:)|^[\w.-]+\/[\w.-]+(#.*)?$/.test(String(spec));
const declaredByLib = Object.keys(libSpecs).filter((name) => fromRegistry(libSpecs[name]));
const libVersion = (name) => libLock[`node_modules/${name}`]?.version;
const declaredHere = (name) => name in (manifest.dependencies ?? {}) || name in (manifest.devDependencies ?? {});

const specsFor = (section) =>
  Object.keys(manifest[section] ?? {})
    .filter((name) => declaredByLib.includes(name) && libVersion(name))
    .map((name) => `${name}@${libVersion(name)}`);

// Transitive-only packages: pin through `overrides`. lib's runtime/peer packages at the top level (the project
// runs them); lib's devDependencies under lib's own package name (only lib's copy is lib's).
const libRuntime = [...Object.keys(libManifest.dependencies ?? {}), ...Object.keys(libManifest.peerDependencies ?? {})].filter((name) => declaredByLib.includes(name));
const transitive = libRuntime.filter((name) => !declaredHere(name) && libVersion(name));
const transitiveDev = Object.keys(libManifest.devDependencies ?? {}).filter((name) => declaredByLib.includes(name)).filter((name) => !libRuntime.includes(name) && !declaredHere(name) && libVersion(name));
// The project's own overrides stay; every pin for a package lib declares is recomputed from lib's lockfile.
const ownOverrides = Object.entries(manifest.overrides ?? {}).filter(([name]) => !declaredByLib.includes(name) && name !== libManifest.name);
const libPins = transitive.map((name) => [name, libVersion(name)]);
const libDevPins = transitiveDev.length > 0 ? [[libManifest.name, Object.fromEntries(transitiveDev.map((name) => [name, libVersion(name)]))]] : [];
const overrides = [...ownOverrides, ...libPins, ...libDevPins].sort(([a], [b]) => a.localeCompare(b));
if (overrides.length > 0 || manifest.overrides !== undefined) {
  manifest.overrides = Object.fromEntries(overrides);
  writeFileSync('package.json', `${JSON.stringify(manifest, null, 2)}\n`);
}

const production = specsFor('dependencies');
const development = specsFor('devDependencies');

if (production.length > 0) execFileSync('npm', ['install', '--save-exact', ...production], { stdio: 'inherit' });
if (development.length > 0) execFileSync('npm', ['install', '--save-dev', '--save-exact', ...development], { stdio: 'inherit' });
if (production.length === 0 && development.length === 0) execFileSync('npm', ['install'], { stdio: 'inherit' });
console.log(`Aligned on lib: ${[...production, ...development].join(' ') || 'nothing declared here'}; pinned through overrides: ${[...transitive, ...transitiveDev].join(' ') || 'none'}`);
