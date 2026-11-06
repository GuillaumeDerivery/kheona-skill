#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Every input a workflow or action passes to one of this repository's actions must be declared there: GitHub only
# warns about an unknown input, and the value is lost. Then the deploy action's input check, run for real.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); cd "$HERE" || exit 64
node --input-type=module <<'JS'
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
let pass = 0, failed = 0;
const fail = (m) => { failed++; console.log(`FAIL ${m}`); };
const ok = (m) => { pass++; console.log(`ok   ${m}`); };
function declared(name) {
  const inputs = {};
  let inside = false, cur = null;
  for (const line of readFileSync(`.github/actions/${name}/action.yml`, 'utf8').split('\n')) {
    if (/^\S/.test(line)) { inside = /^inputs:\s*$/.test(line); cur = null; continue; }
    if (!inside) continue;
    let m;
    if ((m = line.match(/^ {2}([\w-]+):\s*$/))) { cur = m[1]; inputs[cur] = { required: false }; continue; }
    if (cur && /^ {4}required:\s*true\b/.test(line)) inputs[cur].required = true;
  }
  return inputs;
}
function calls(file) {
  const out = [], lines = readFileSync(file, 'utf8').split('\n');
  lines.forEach((line, i) => {
    const m = line.match(/^(\s*)(?:- )?(?:name: .*)?uses:\s*(?:\$|\.)\/\.github\/actions\/([\w-]+)/);
    if (!m) return;
    const stepIndent = line.search(/\S/);
    const keys = [];
    for (let j = i + 1; j < lines.length; j++) {
      const l = lines[j];
      if (!l.trim()) continue;
      const indent = l.search(/\S/);
      if (indent < stepIndent || (indent === stepIndent && !/^\s*with:\s*$/.test(l) && !/^\s*[\w-]+:/.test(l))) break;
      if (/^\s*- /.test(l) && indent <= stepIndent) break;
      if (/^\s*with:\s*$/.test(l)) {
        for (let k = j + 1; k < lines.length; k++) {
          const w = lines[k];
          if (!w.trim()) continue;
          if (w.search(/\S/) <= indent) break;
          const key = w.match(/^\s*([\w-]+):/);
          if (key && w.search(/\S/) === lines[j + 1].search(/\S/)) keys.push(key[1]);
        }
        break;
      }
    }
    out.push({ action: m[2], keys, line: i + 1 });
  });
  return out;
}
const files = [
  ...readdirSync('.github/workflows').filter((f) => f.endsWith('.yml')).map((f) => `.github/workflows/${f}`),
  ...readdirSync('.github/actions').map((d) => `.github/actions/${d}/action.yml`).filter(existsSync),
];
for (const file of files) for (const c of calls(file)) {
  const inputs = declared(c.action);
  const unknown = c.keys.filter((k) => !inputs[k]);
  const missing = Object.keys(inputs).filter((k) => inputs[k].required && !c.keys.includes(k));
  if (unknown.length) fail(`${file}:${c.line} passes ${unknown.join(', ')} to ${c.action}, which does not declare it`);
  else if (missing.length) fail(`${file}:${c.line} leaves out ${missing.join(', ')} of ${c.action}`);
  else ok(`${file}:${c.line} ${c.action}`);
}
// The deploy action's own check, as it runs in a job.
const src = readFileSync('.github/actions/kskill-deploy-eks/action.yml', 'utf8').split('\n');
const start = src.findIndex((l) => /- name: Check the inputs/.test(l));
const runAt = src.findIndex((l, i) => i > start && /^\s+run: \|\s*$/.test(l));
const body = [];
for (let i = runAt + 1; i < src.length && (!src[i].trim() || src[i].startsWith('        ')); i++) body.push(src[i].slice(8));
const base = { IN_REGION: 'eu-west-1', IN_CLUSTER: 'example-cluster', IN_REPOSITORY: 'example', IN_TARGETS: '[{"namespace":"staging","deployments":["example"]}]' };
function check(name, env, code, text) {
  const r = spawnSync('bash', ['-c', body.join('\n')], { env: { PATH: process.env.PATH, ...base, ...env }, encoding: 'utf8' });
  if (r.status === code && r.stdout.includes(text)) ok(name);
  else fail(`${name} (exit ${r.status}: ${r.stdout.trim()})`);
}
check('a role needs no stored key', { IN_ROLE: 'arn:aws:iam::111122223333:role/example' }, 0, '');
check('stored keys need no role', { IN_KEY_ID: 'id', IN_SECRET: 'secret' }, 0, '');
check('neither is refused, naming the key', {}, 1, "Deploy input 'aws-access-key-id' is empty");
check('half a key is refused', { IN_KEY_ID: 'id' }, 1, "Deploy input 'aws-secret-access-key' is empty");
console.log(`${pass} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
JS
