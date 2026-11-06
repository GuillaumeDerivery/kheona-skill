// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
// not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// what this mutation run mutates. Only the files changed since the last successful run, from the repository's
// root, by the inbox's mutation-setup job (kskill-inbox.yml) (full history checked out):
//   node .github/scripts/kskill-mutation-scope.mjs --config <stryker config> [--base <sha>]
// The base is the commit of the newest unexpired `mutation-base` artifact on this branch (the mutation job uploads it
// after a green Stryker run), read with GH_TOKEN (actions: read) from GH_REPO; --base names it instead.
// Writes to $GITHUB_OUTPUT:
//   mode=full     no base (first run, artifact expired, an API error), a base this branch does not contain, or a change
//                 to the Stryker config or the shared options: the config's own `mutate`, nothing passed
//   mode=changed  mutate=<a,b,...>: the files added, modified or renamed since the base that the config's `mutate`
//                 globs take in (and no negated glob excludes), passed to Stryker as --mutate
//   mode=none     no such file: the Stryker job is skipped
// and base=<sha or empty>. Why the list and not Stryker's --incremental: with the command runner Stryker sees the suite
// as one opaque test and would keep an old "Survived" after the test that kills it lands; a fresh run on the changed
// files has no stale verdict. Never writes to GitHub; any doubt falls back to the full scope.
import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, readFileSync } from 'node:fs';
import { matchesGlob, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const argv = process.argv.slice(2);
const opt = (n) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : undefined; };
const config = opt('--config');
if (!config || !existsSync(config)) { console.error(`::error::No Stryker config ${config ?? '(--config)'}.`); process.exit(1); }
const SHARED = '.github/config/kskill-stryker.mjs';
const git = (...a) => execFileSync('git', a, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
const write = (file, lines) => { if (file) appendFileSync(file, `${lines.join('\n')}\n`); };

async function mutateGlobs() {
  if (config.endsWith('.json')) return JSON.parse(readFileSync(config, 'utf8')).mutate;
  return (await import(pathToFileURL(resolve(config)).href)).default?.mutate;
}
function lastBase() {
  const branch = process.env.GITHUB_REF_NAME, repo = process.env.GH_REPO;
  if (!branch || !repo) return '';
  try {
    const out = execFileSync('gh', ['api', `repos/${repo}/actions/artifacts?name=mutation-base&per_page=50`, '--jq',
      `[.artifacts[] | select(.expired | not) | select(.workflow_run.head_branch == ${JSON.stringify(branch)})][0].workflow_run.head_sha // ""`],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    return out.trim();
  } catch { return ''; }
}

function decide(base, globs) {
  if (!Array.isArray(globs) || !globs.length || !globs.every((g) => typeof g === 'string')) return { mode: 'full', why: `${config} has no readable \`mutate\` list` };
  if (!base) return { mode: 'full', why: 'no earlier successful run on this branch' };
  if (!/^[0-9a-f]{40}$/.test(base)) return { mode: 'full', why: `base ${base} is not a commit sha` };
  try { git('merge-base', '--is-ancestor', base, 'HEAD'); } catch { return { mode: 'full', why: `base ${base.slice(0, 7)} is not in this branch's history` }; }
  const changed = git('diff', '--name-only', '--no-renames', '--diff-filter=AM', '-z', base, 'HEAD').split('\0').filter(Boolean);
  if (changed.includes(config) || changed.includes(SHARED)) return { mode: 'full', why: `the Stryker configuration changed since ${base.slice(0, 7)}` };
  const pats = globs.map((g) => g.replace(/:\d+(:\d+)?-\d+(:\d+)?$/, ''));
  const take = pats.filter((g) => !g.startsWith('!')), drop = pats.filter((g) => g.startsWith('!')).map((g) => g.slice(1));
  const files = changed.filter((f) => take.some((g) => matchesGlob(f, g)) && !drop.some((g) => matchesGlob(f, g)));
  if (files.some((f) => /[,\s]/.test(f))) return { mode: 'full', why: 'a changed file name has a comma or a space' };
  return files.length ? { mode: 'changed', files, why: `${files.length} file(s) in scope changed since ${base.slice(0, 7)}` }
    : { mode: 'none', why: `no file in scope changed since ${base.slice(0, 7)}` };
}

const base = opt('--base') ?? lastBase();
let globs;
try { globs = await mutateGlobs(); } catch { globs = undefined; }
const d = decide(base, globs);
write(process.env.GITHUB_OUTPUT, [`mode=${d.mode}`, `mutate=${(d.files || []).join(',')}`, `base=${base}`]);
const lines = [`Mutation scope: ${d.mode} (${d.why}).`, ...(d.files || []).map((f) => `- \`${f}\``)];
write(process.env.GITHUB_STEP_SUMMARY, ['## Mutation scope', '', ...lines]);
console.log(lines.join('\n'));
