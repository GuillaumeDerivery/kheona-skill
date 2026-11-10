#!/usr/bin/env node
// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
// not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// The caller files of a repository: about one small file per event, each calling a shared workflow of this repository
// at one version: by its commit, or for the production callers (`"pin": "tag"` in callers.json: the deploy and the
// delivery a version tag starts) by its immutable version tag, which is what the production roles' trust names
// (job_workflow_ref). The setup command (scripts/kskill-setup.sh) writes them; the repository check compares them with what this version expects
// (present, right version, right content); a version bump regenerates them in the same PR.
//
// Usage:
//   kskill-callers.mjs list  [--repo DIR]                        the callers this repository needs, as JSON
//   kskill-callers.mjs write --self owner/kheona-skill --sha SHA --version v1.2.3 [--repo DIR]   (version: vX.Y.Z)
//   kskill-callers.mjs check [--repo DIR] [--self ...] [--json]  exit 1 when one is missing or edited
//   kskill-callers.mjs stack [--repo DIR]                        stack=<s> and deploys=<true|false>, $GITHUB_OUTPUT
//                                                                lines; exit 1 when the repository has no stack
// What a repository needs comes from what it is: its files (the stack) and .kheona.json (role, workflows.cd). The
// shared workflows read the same, through `stack` (kskill-ci.yml, kskill-main.yml): a caller never names its stack.
// With workflows.cd.target "custom", the callers marked `"custom": true` get a second job that runs the repository's own
// deploy workflow (workflows.cd.custom.workflow, default deploy.yml, `on: workflow_call` with the inputs environment
// and version) once the shared workflow checked the release and passed the gate (its output deploy == "custom").
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const TABLE = JSON.parse(readFileSync(join(HERE, '..', '.github', 'callers.json'), 'utf8'));
const argv = process.argv.slice(2);
const opt = (name, fallback = '') => { const i = argv.indexOf(name); return i < 0 ? fallback : argv[i + 1]; };
const repo = opt('--repo', '.');
const has = (f) => existsSync(join(repo, f));
const CFG = has('.kheona.json') ? JSON.parse(readFileSync(join(repo, '.kheona.json'), 'utf8')) : {};

export function stackOf() {
  if (has('pubspec.yaml')) return 'flutter';
  if (has('Pipfile') || has('pyproject.toml')) return 'python';
  if (has('package.json')) return 'node';
  return CFG.role === 'infra' ? 'infra' : '';
}

export function needed() {
  const stack = stackOf();
  const role = CFG.role || 'project';
  const out = [];
  // No stack: nothing to build or test, but @claude, the inbox and release-please need none.
  if (!stack) return { stack, files: ['kskill-claude.yml', 'kskill-inbox.yml', 'kskill-release-please.yml'] };
  out.push('kskill-pr.yml');
  if (stack === 'infra') return { stack, files: out };
  out.push('kskill-claude.yml', 'kskill-inbox.yml', 'kskill-release-please.yml');
  out.push('kskill-main.yml');
  // What ships from a version tag: an app's delivery, a service's deploy; a library releases only.
  if (role !== 'library' && stack === 'flutter') {
    if (CFG.workflows?.cd?.enabled !== false) out.push('kskill-deliver-flutter.yml');
  } else if (role !== 'library' && (CFG.workflows?.cd?.staging || CFG.workflows?.cd?.prod)) out.push('kskill-deploy.yml');
  // A template or a library may be forked: its forks get the notice of each change (a fork with none is a no-op).
  if (role === 'template' || role === 'library') out.push('kskill-sync-upstream.yml');
  return { stack, files: out };
}

// What a push to main deploys: staging, for a service (Node or Python, a template included), never for a library, an
// app or an infra repository. kskill-main.yml reads it through `stack`.
export function deploys(stack = stackOf(), role = CFG.role || 'project') {
  return role !== 'library' && (stack === 'node' || stack === 'python');
}

// renovate.json extends this repository's preset at the callers' version tag, never the default branch.
const PRESET = /("github>[\w.-]+\/kheona-skill\/\/renovate\/[\w.-]+)(#[^"]*)?"/g;
function presetText(version) {
  if (!has('renovate.json')) return null;
  const text = readFileSync(join(repo, 'renovate.json'), 'utf8');
  return { text, want: text.replace(PRESET, (_, base) => `${base}#${version}"`) };
}

const yamlValue = (v) => (typeof v === 'string' && !/^[\w.-]+$/.test(v) ? JSON.stringify(v) : String(v));
function dumpYaml(value, indent) {
  const pad = ' '.repeat(indent);
  return Object.entries(value).map(([k, v]) => {
    if (v === null || (typeof v === 'object' && !Array.isArray(v) && !Object.keys(v).length)) return `${pad}${k}:\n`;
    if (Array.isArray(v)) return `${pad}${k}: [${v.map(yamlValue).join(', ')}]\n`;
    if (typeof v === 'object') return `${pad}${k}:\n${dumpYaml(v, indent + 2)}`;
    return `${pad}${k}: ${yamlValue(v)}\n`;
  }).join('');
}

export function customWorkflow() {
  if (CFG.workflows?.cd?.target !== 'custom') return '';
  const f = CFG.workflows?.cd?.custom?.workflow || 'deploy.yml';
  if (!/^[\w.-]+\.ya?ml$/.test(f) || f.startsWith('kskill-')) throw new Error(`workflows.cd.custom.workflow '${f}' must be a workflow file name, not kskill-*`);
  return f;
}

export function callerText(file, { self, sha, version }) {
  const c = TABLE[file];
  const ref = c.pin === 'tag' ? version : `${sha} # ${version}`;
  // kskill-main.yml hands staging over only where it deploys staging.
  const custom = c.custom && (file !== 'kskill-main.yml' || deploys()) ? customWorkflow() : '';
  const lines = [
    `# Generated by ${self} scripts/kskill-callers.mjs at ${version}. Do not edit: run scripts/kskill-setup.sh --apply again.`,
    `name: ${c.name}`,
    '',
    'on:',
    dumpYaml(c.events, 2).trimEnd(),
    '',
    'permissions: {}',
    '',
    'jobs:',
    '  call:',
    '    permissions:',
    ...Object.entries(c.permissions).sort().map(([k, v]) => `      ${k}: ${v}`),
    `    uses: ${self}/.github/workflows/${file}@${ref}`,
  ];
  const withs = [];
  for (const i of c.dispatchInputs) {
    withs.push(`      ${i}: \${{ ${c.inputTypes[i] === 'boolean' ? `inputs.${i} == true` : `inputs.${i}`} }}`);
  }
  if (withs.length) lines.push('    with:', ...withs);
  if (c.secrets.length) lines.push('    secrets:', ...c.secrets.map((s) => `      ${s}: \${{ secrets.${s} }}`));
  if (custom) {
    lines.push('', '  # workflows.cd.target "custom": the release is checked and the gate passed; this repository deploys.',
      '  custom:', '    needs: call', "    if: needs.call.outputs.deploy == 'custom'",
      '    permissions:', '      contents: read', '      id-token: write',
      `    uses: ./.github/workflows/${custom}`, '    with:',
      '      environment: ${{ needs.call.outputs.environment }}', '      version: ${{ needs.call.outputs.version }}',
      '    secrets: inherit');
  }
  return `${lines.join('\n')}\n`;
}

function pinOf(text) {
  const m = text.match(/^ +uses: ([\w.-]+\/[\w.-]+)\/\.github\/workflows\/[\w.-]+@([0-9a-f]{40}) # (\S+)$/m);
  if (m) return { self: m[1], sha: m[2], version: m[3] };
  const t = text.match(/^ +uses: ([\w.-]+\/[\w.-]+)\/\.github\/workflows\/[\w.-]+@(v\d+\.\d+\.\d+)$/m);
  return t ? { self: t[1], sha: '', version: t[2] } : null;
}

const cmd = argv[0];
if (cmd === 'list') {
  const { stack, files } = needed();
  console.log(JSON.stringify({ stack, callers: files.map((f) => ({ file: f, caller: TABLE[f].caller, secrets: TABLE[f].secrets })) }, null, 2));
} else if (cmd === 'write') {
  const self = opt('--self'); const sha = opt('--sha'); const version = opt('--version');
  if (!/^[\w.-]+\/[\w.-]+$/.test(self) || !/^[0-9a-f]{40}$/.test(sha) || !/^v\d+\.\d+\.\d+$/.test(version)) { console.error('usage: write --self owner/name --sha <40 hex> --version vX.Y.Z'); process.exit(64); }
  const { files } = needed();
  mkdirSync(join(repo, '.github', 'workflows'), { recursive: true });
  for (const f of files) {
    writeFileSync(join(repo, '.github', 'workflows', TABLE[f].caller), callerText(f, { self, sha, version }));
    console.log(`wrote .github/workflows/${TABLE[f].caller}`);
  }
  const preset = presetText(version);
  if (preset && preset.want !== preset.text) { writeFileSync(join(repo, 'renovate.json'), preset.want); console.log(`pinned renovate.json's preset at ${version}`); }
} else if (cmd === 'check') {
  const { stack, files } = needed();
  const readPin = (g) => { const p = `.github/workflows/${TABLE[g].caller}`; return has(p) ? pinOf(readFileSync(join(repo, p), 'utf8')) : null; };
  const problems = [];
  const known = new Set(Object.values(TABLE).map((c) => c.caller));
  for (const f of files) {
    const path = `.github/workflows/${TABLE[f].caller}`;
    if (!has(path)) { problems.push({ path, kind: 'missing', message: 'missing: run scripts/kskill-setup.sh --apply' }); continue; }
    const text = readFileSync(join(repo, path), 'utf8');
    const pin = pinOf(text);
    if (!pin) { problems.push({ path, kind: 'edited', message: 'calls no pinned version of the shared workflows' }); continue; }
    if (opt('--self') && pin.self !== opt('--self')) { problems.push({ path, kind: 'edited', message: 'calls another repository' }); continue; }
    if (pin.sha === '' && TABLE[f].pin !== 'tag') { problems.push({ path, kind: 'edited', message: 'pinned by a tag: this caller pins a commit' }); continue; }
    const sameVersion = files.map((g) => readPin(g)).filter(Boolean);
    if (sameVersion.some((p) => p.version !== pin.version)) problems.push({ path, kind: 'edited', message: `the callers name different versions (${[...new Set(sameVersion.map((p) => p.version))].join(', ')}): run scripts/kskill-setup.sh --apply at one` });
    const sha = pin.sha || sameVersion.find((p) => p.sha)?.sha || '';
    if (text !== callerText(f, { ...pin, sha })) problems.push({ path, kind: 'edited', message: 'differs from what this version expects: run scripts/kskill-setup.sh --apply again' });
  }
  const version = files.map((g) => readPin(g)).find(Boolean)?.version;
  const preset = version && presetText(version);
  if (preset && preset.want !== preset.text) problems.push({ path: 'renovate.json', kind: 'edited', message: `extends the preset at another ref than ${version}: run scripts/kskill-setup.sh --apply again` });
  const wf = join(repo, '.github', 'workflows');
  for (const n of existsSync(wf) ? readdirSync(wf) : []) {
    if (n.startsWith('kskill-') && !known.has(n)) problems.push({ path: `.github/workflows/${n}`, kind: 'unknown', message: 'not a caller of this version' });
  }
  const ships = files.some((f) => f === 'kskill-deploy.yml' || f === 'kskill-deliver-flutter.yml');
  if (argv.includes('--json')) console.log(JSON.stringify({ ok: !problems.length, stack, ships, problems }));
  else for (const p of problems) console.error(`${p.path}: ${p.message}`);
  process.exit(problems.length ? 1 : 0);
} else if (cmd === 'stack') {
  const stack = stackOf();
  if (!stack) {
    console.error('::error::No stack: no pubspec.yaml, Pipfile, pyproject.toml or package.json at the root, and .kheona.json\'s role is not "infra".');
    process.exit(1);
  }
  console.log(`stack=${stack}\ndeploys=${deploys(stack)}`);
} else {
  console.error('usage: kskill-callers.mjs {list|write|check|stack} [--repo DIR]');
  process.exit(64);
}
