#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# A job calling a workflow must grant every permission the called jobs ask for: GitHub refuses the whole run otherwise,
# before any job starts (startup_failure). Static, over every job-level `uses:` of .github/workflows.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); cd "$HERE" || exit 64
node --input-type=module <<'JS'
import { readFileSync, readdirSync } from 'node:fs';
const dir = '.github/workflows';
const rank = { none: 0, read: 1, write: 2 };
function parse(name) {
  const lines = readFileSync(`${dir}/${name}`, 'utf8').split('\n');
  const wf = { perms: {}, jobs: {} };
  let job = null, block = null;
  for (const line of lines) {
    if (/^\S/.test(line)) {
      job = null;
      block = /^permissions:\s*$/.test(line) ? wf.perms : null;
      const inline = line.match(/^permissions:\s*\{\}/);
      if (inline) wf.perms = {};
      continue;
    }
    let m;
    if ((m = line.match(/^ {2}([\w-]+):\s*$/)) && !block) { job = wf.jobs[m[1]] = { perms: null, uses: null }; continue; }
    if ((m = line.match(/^ {2}([\w-]+):\s*$/))) { block = null; job = wf.jobs[m[1]] = { perms: null, uses: null }; continue; }
    if (job && /^ {4}permissions:\s*\{\}/.test(line)) { job.perms = {}; block = null; continue; }
    if (job && /^ {4}permissions:\s*$/.test(line)) { block = job.perms = {}; continue; }
    if (job && (m = line.match(/^ {4}uses:\s*\.\/\.github\/workflows\/(\S+)/))) { job.uses = m[1]; block = null; continue; }
    if (block && (m = line.match(/^ +([\w-]+):\s*(read|write|none)\b/))) { block[m[1]] = m[2]; continue; }
    if (/^ {4}\S/.test(line)) block = null;
  }
  return wf;
}
const files = readdirSync(dir).filter((f) => f.endsWith('.yml'));
const all = Object.fromEntries(files.map((f) => [f, parse(f)]));
function needs(name) {
  const out = {};
  for (const job of Object.values(all[name].jobs)) {
    const want = job.uses ? needs(job.uses) : (job.perms ?? all[name].perms);
    for (const [k, v] of Object.entries(want)) if ((rank[out[k]] ?? 0) < rank[v]) out[k] = v;
  }
  return out;
}
let pass = 0, failed = 0;
for (const f of files) for (const [id, job] of Object.entries(all[f].jobs)) {
  if (!job.uses) continue;
  const have = job.perms ?? all[f].perms;
  const short = Object.entries(needs(job.uses)).filter(([k, v]) => (rank[have[k]] ?? 0) < rank[v]).map(([k, v]) => `${k}: ${v}`);
  if (short.length) { failed++; console.log(`FAIL ${f} job ${id} calls ${job.uses}, missing ${short.join(', ')}`); }
  else { pass++; console.log(`ok   ${f} job ${id}`); }
}
console.log(`${pass} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
JS
