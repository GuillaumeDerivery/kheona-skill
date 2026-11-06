// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
// not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// The shared Stryker options (mutation testing), for every Node repository whose .kheona.json sets workflows.mutation
// (the mutation job of kskill-inbox.yml).
// The repository's own stryker.config.mjs spreads them and adds its test command, what it mutates, its timeouts and
// thresholds; its `mutation` script names it (`stryker run stryker.config.mjs`):
//   import base from './.github/config/kskill-stryker.mjs';
//   export default { ...base, commandRunner: { command: 'node --test "tests/**/*.ts"' }, mutate: ['src/**/*.ts'] };
// The reports land where the inbox's mutation job uploads them (`workflows.mutation.reportPath`, reports/mutation/).
export default {
  testRunner: 'command',
  coverageAnalysis: 'off',
  incremental: true,
  ignorePatterns: ['submodules', 'dist', 'coverage', 'reports', '.claude', '.stryker-tmp'],
  reporters: ['clear-text', 'html', 'json'],
  htmlReporter: { fileName: 'reports/mutation/mutation.html' },
  jsonReporter: { fileName: 'reports/mutation/mutation.json' },
};
