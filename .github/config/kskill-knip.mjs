// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
// not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// The shared knip options (dead code), for every Node repository whose `deadCode` check is on. The
// repository's own knip.config.mjs spreads them and adds its entry points and project files; its `knip` script
// names it (`knip --config knip.config.mjs`):
//   import base from './.github/config/kskill-knip.mjs';
//   export default { ...base, entry: ['src/index.ts', 'tests/**/*.ts'], project: ['src/**/*.ts', 'tests/**/*.ts'] };
export default {
  // Tests import the compiled dist/...js (Node cannot run the .ts sources' .js specifiers): map it back to src, from
  // tests/ and from one directory below it (tests/helpers/). A repository with deeper tests adds its own depth.
  paths: { '../dist/*': ['./src/*'], '../../dist/*': ['./src/*'] },
};
