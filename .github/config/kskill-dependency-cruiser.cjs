// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
// not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// The shared dependency-cruiser rules (import graph), for every Node repository whose `importGraph` check is
// on. The repository's own .dependency-cruiser.cjs extends it and adds its layering rules:
//   module.exports = { extends: './node_modules/kheona-skill/.github/config/kskill-dependency-cruiser.cjs', forbidden: [ ...its rules ] };
// The graph is the one TypeScript emits (tsPreCompilationDeps: false): an import used only as a type is erased at
// compile time and cannot deadlock module initialisation, so it is not an edge.
module.exports = {
  forbidden: [
    {
      name: 'no-circular',
      comment: 'A runtime import cycle makes module initialisation order-dependent.',
      severity: 'error',
      from: {},
      to: { circular: true },
    },
    {
      name: 'not-to-unresolvable',
      comment: 'Every import resolves: a typo or a missing package fails here, not at runtime.',
      severity: 'error',
      from: {},
      to: { couldNotResolve: true },
    },
  ],
  options: {
    // the shared library resolves into submodules/lib through npm's file: link: a separate repository with its own rules.
    doNotFollow: { path: '^(node_modules|submodules)/' },
    // ESM-only packages expose themselves through `exports` conditions.
    enhancedResolveOptions: { exportsFields: ['exports'], conditionNames: ['import', 'node', 'default'] },
    tsConfig: { fileName: 'tsconfig.json' },
    tsPreCompilationDeps: false,
  },
};
