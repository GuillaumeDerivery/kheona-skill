// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
// not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// The guard: nothing private reaches this repository. Fails on any term of a private list, in tracked file names and
// contents, commit messages, and any text given on the command line. The list is never in this repository, and the
// report names the place, never the term, so a log cannot confirm one.
//
// Usage: node kskill-guard.mjs [--repo DIR] [--self owner/name] [--commits RANGE] [--text-file FILE]... [--no-files]
// Env:   KSKILL_GUARD_LIST, the path of the list: one term a line, case-insensitive, # comments and blank lines ignored.
//        Or KSKILL_GUARD_TERMS, the same text (a secret).
// --self: that exact string is removed before searching, so the repository may name itself; its owner alone stays forbidden.
// Authorized authors, whose identity (name and email) is not scanned, their commit messages still are: the owner's own
// GitHub identity (GitHub writes it on a merge), and the repository's own App, named after it: `<name>[bot]` with its
// noreply address `<id>+<name>[bot]@users.noreply.github.com` (release-please commits as the App).
// Exit 0 clean, 1 a hit, 64 misuse (no list: a guard that reads nothing must never pass).
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const argv = process.argv.slice(2);
const all = (name) => argv.flatMap((a, i) => (a === name ? [argv[i + 1]] : []));
const one = (name, fallback) => all(name).at(-1) ?? fallback;
const repo = one('--repo', '.');
const self = one('--self', '');
const range = one('--commits', '');
const listText = process.env.KSKILL_GUARD_TERMS || (process.env.KSKILL_GUARD_LIST ? readFileSync(process.env.KSKILL_GUARD_LIST, 'utf8') : '');
const terms = listText.split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#')).map((l) => l.toLowerCase());
if (!terms.length) { console.error('kskill-guard: no list (KSKILL_GUARD_LIST or KSKILL_GUARD_TERMS): nothing was checked.'); process.exit(64); }

// A real cloud account id: twelve digits, except the documented placeholder.
const accountId = /(?<![0-9])(?!111122223333)[0-9]{12}(?![0-9])/;
const selfLower = self.toLowerCase();
const owner = selfLower.split('/')[0];
const ownerEmail = new RegExp(`^[0-9]+\\+${owner.replace(/[^a-z0-9-]/g, '')}@users\\.noreply\\.github\\.com$`, 'i');
const appName = selfLower.split('/')[1]?.replace(/[^a-z0-9-]/g, '') || '';
const appEmail = appName ? new RegExp(`^[0-9]+\\+${appName}\\[bot\\]@users\\.noreply\\.github\\.com$`, 'i') : null;
const authorized = (name, email) => ownerEmail.test(email) || (appEmail && appEmail.test(email) && name.toLowerCase() === `${appName}[bot]`);
const hits = [];
function scan(where, text) {
  text.split('\n').forEach((line, i) => {
    const l = (selfLower ? line.toLowerCase().replaceAll(selfLower, '') : line.toLowerCase());
    const n = terms.filter((t) => l.includes(t)).length;
    if (n) hits.push(`${where}:${i + 1}: ${n} forbidden term(s)`);
    else if (accountId.test(l)) hits.push(`${where}:${i + 1}: an account id`);
  });
}
const git = (...a) => execFileSync('git', ['-C', repo, ...a], { encoding: 'utf8', maxBuffer: 1 << 28 });

if (!argv.includes('--no-files')) {
  for (const f of git('ls-files').split('\n').filter(Boolean)) {
    scan(`name of ${f}`, f);
    let body;
    try { body = readFileSync(join(repo, f)); } catch { continue; }
    if (!body.subarray(0, 8000).includes(0)) scan(f, body.toString('utf8'));
  }
}
if (range) {
  for (const sha of git('rev-list', range).split('\n').filter(Boolean)) {
    // An authorized author's identity is not scanned (above); any other identity is.
    const [an, ae, cn, ce] = git('show', '-s', '--format=%an%n%ae%n%cn%n%ce', sha).split('\n');
    const people = [[an, ae], [cn, ce]].filter(([name, email]) => !authorized(name, email)).flat();
    scan(`commit ${sha.slice(0, 12)}`, [...people, git('show', '-s', '--format=%B', sha)].join('\n'));
  }
}
for (const f of all('--text-file')) scan(`text ${f}`, readFileSync(f, 'utf8'));

for (const h of hits) console.log(process.env.GITHUB_ACTIONS === 'true' ? `::error::${h}` : h);
console.log(`guard: ${terms.length} term(s), ${hits.length} hit(s)`);
process.exit(hits.length ? 1 : 0);
