// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
// not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// The shared Prettier options, for every Node repository whose `format` check is on. The repository's own
// prettier.config.mjs spreads them and overrides only what it must, saying why:
//   import base from 'kheona-skill/prettier';
//   export default { ...base };
export default {
  singleQuote: true,
  printWidth: 200,
  overrides: [{ files: ['*.yml', '*.yaml'], options: { singleQuote: false } }],
};
