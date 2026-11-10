// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
// not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// Enforces the lib's CLAUDE.md, "Rules for any project consuming this library", rule 1: this project must run
// exactly the dependency versions the lib runs. Two copies of mongodb/express/joi/... are two module instances
// at runtime (instanceof ObjectId fails across the boundary, middleware types disagree).
//
// For every package that <lib>/package.json declares (dependencies, devDependencies, peerDependencies) AND that
// both lockfiles resolve at the top level, the version in ./package-lock.json must equal the one in
// <lib>/package-lock.json. A package lib takes from git, a URL or a path has no registry version: not compared.
//
// It reads the two lockfiles, not the two node_modules trees: `npm ci` in the root treats the file:-linked lib
// as part of its own tree and prunes <lib>/node_modules down to a handful of entries, so comparing the
// installed trees after the root install compares nothing and always passes. The lockfiles are what `npm ci`
// installs from, so they are the versions that will run, and the check needs no install at all.
//
// Usage, from the repository root: node .github/scripts/kskill-check-lib-versions.mjs [lib path, default submodules/lib]
// Exit 0: all shared packages agree. Exit 1: a list of mismatches and the fix.
// Exit 2: precondition failed (a lockfile is missing, or nothing was compared).
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const LIB = process.argv[2] ?? 'submodules/lib';

const readJson = (path) => JSON.parse(readFileSync(path, 'utf8'));

for (const tree of ['.', LIB]) {
  if (!existsSync(join(tree, 'package-lock.json'))) {
    console.error(`::error::${tree}/package-lock.json is missing (is the submodule checked out?).`);
    process.exit(2);
  }
}

const rootPackages = readJson('package-lock.json').packages ?? {};
const libPackages = readJson(join(LIB, 'package-lock.json')).packages ?? {};
const libManifest = readJson(join(LIB, 'package.json'));
const libSpecs = { ...libManifest.peerDependencies, ...libManifest.devDependencies, ...libManifest.dependencies };
const fromRegistry = (spec) => !/^(git[+:]|github:|gitlab:|bitbucket:|https?:|file:|link:|workspace:)|^[\w.-]+\/[\w.-]+(#.*)?$/.test(String(spec));
const declared = new Set(Object.keys(libSpecs).filter((name) => fromRegistry(libSpecs[name])));

const mismatches = [];
let compared = 0;
for (const name of [...declared].sort()) {
  const root = rootPackages[`node_modules/${name}`]?.version ?? null;
  const lib = libPackages[`node_modules/${name}`]?.version ?? null;
  if (root === null || lib === null) {
    continue; // not resolved at the top level on one side: nothing to compare
  }
  compared += 1;
  if (root !== lib) {
    mismatches.push({ name, root, lib });
  }
}

if (compared === 0) {
  // A check that compares nothing passes for the wrong reason; fail instead.
  console.error(`::error::No package declared by ${LIB} is resolved in both lockfiles, so nothing was compared.`);
  process.exit(2);
}

if (mismatches.length > 0) {
  console.error(`::error::Locked versions differ from ${LIB}, which this project must match exactly:`);
  for (const { name, root, lib } of mismatches) {
    console.error(`::error::  ${name}: this project ${root}, lib ${lib}`);
  }
  console.error(
    'Dependencies shared with lib move by bumping lib, never on their own. Bump the ' +
      `${LIB} pointer to a lib release that has the newer versions, then refresh ` +
      'this lockfile (npm ci / npm update); or put the lockfile back to the version lib runs.'
  );
  process.exit(1);
}

console.log(`OK: ${compared} packages shared with ${LIB} are locked at identical versions.`);
