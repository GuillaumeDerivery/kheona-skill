// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
// not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// The one definition of "a token for every owner": mints an installation token of the automation App for
// each account it is installed on (no list kept here), for the callers that work across owners: the template sync,
// the doctor, lib's release notice, the upstream sync between a parent and its forks, a fork's Sentry triage reading
// its parent. A workflow that touches only its own repository, or kheona-skill and lib, uses
// the kskill-token action instead.
//
// Usage: node kskill-app-tokens.mjs <dir> [--install] [--self]
//   --self: not every owner, only this repository's (its own token) and, for a fork, its parent's (the broker's
//   /token with the parent named, which it checks): what a job inside one repository needs, such as the Sentry triage.
//   Without it, POST /tokens, which the broker keeps for the repositories its policy lists in acrossOwners.
// Env:   KSKILL_TOKEN_BROKER_URL, and the job's OIDC identity (id-token: write).
// Writes <dir>/tokens.json ({ "<owner, lower case>": "<token>" }, mode 600) and two commands in <dir>/bin:
//   gh                      runs the real gh with GH_TOKEN set to the token of the owner the command names
//                           (-R/--repo, a repos/<owner>/ API path, a github.com/<owner>/ URL, `repo clone|view|edit
//                           <owner>/<name>`), else of GH_REPO's owner, the current clone's origin, GITHUB_REPOSITORY_OWNER;
//   git-credential-kskill   the same for git over https://github.com/<owner>/...
// Both commands run under bash 3.2 too (macOS).
// In GitHub Actions every token is masked. --install (Actions only) also puts <dir>/bin first on the PATH of the next
// steps, sets the git credential helper globally and exports KSKILL_APP_TOKENS=<dir>/tokens.json (kskill-repos.sh
// lists from it); without it, a step uses them with PATH="<dir>/bin:$PATH" and KSKILL_APP_TOKENS itself.
// Tokens last one hour: mint them in the step before the work, again before a long step. Prints owners only.
import { chmodSync, mkdirSync, writeFileSync, appendFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, resolve } from 'node:path';

const dir = resolve(process.argv[2] || '');
const install = process.argv.includes('--install');
if (!process.argv[2]) { console.error('usage: kskill-app-tokens.mjs <dir>'); process.exit(64); }
const { KSKILL_TOKEN_BROKER_URL: broker, ACTIONS_ID_TOKEN_REQUEST_URL: idUrl, ACTIONS_ID_TOKEN_REQUEST_TOKEN: idToken } = process.env;
if (!broker || !idUrl) {
  console.error('::error::KSKILL_TOKEN_BROKER_URL is not set, or this job has no id-token: write.');
  process.exit(1);
}
const self = process.argv.includes('--self');
const api = (process.env.KSKILL_GITHUB_API || 'https://api.github.com').replace(/\/$/, '');
const identity = (await (await fetch(`${idUrl}&audience=kskill-token-broker`, { headers: { authorization: `bearer ${idToken}` } })).json()).value;
const ask = async (path, body) => {
  const r = await fetch(`${broker.replace(/\/$/, '')}${path}`, {
    method: 'POST', headers: { authorization: `Bearer ${identity}`, 'content-type': 'application/json' }, body: JSON.stringify(body || {}),
  });
  if (!r.ok) {
    const why = await r.json().then((b) => b.error, () => '');
    console.error(`::error::The token broker refused${path === '/tokens' ? '' : ` ${body?.repository || 'this repository'}`}: HTTP ${r.status}${why ? ` ${why}` : ''}`);
    process.exit(1);
  }
  return r.json();
};
let tokens = {};
if (self) {
  const repository = process.env.GITHUB_REPOSITORY || '';
  const owner = repository.split('/')[0].toLowerCase();
  if (!owner) { console.error('::error::GITHUB_REPOSITORY is not set.'); process.exit(1); }
  tokens[owner] = (await ask('/token')).token;
  const info = await (await fetch(`${api}/repos/${repository}`, { headers: { authorization: `Bearer ${tokens[owner]}` } })).json();
  const parent = info.parent?.full_name || '';
  const parentOwner = parent.split('/')[0].toLowerCase();
  if (parent && parentOwner !== owner) tokens[parentOwner] = (await ask('/token', { repository: parent })).token;
  else if (parent) console.log(`::warning::${parent} has this repository's owner: gh and git use this repository's token for it.`);
} else {
  ({ tokens } = await ask('/tokens'));
}
for (const [owner, token] of Object.entries(tokens)) {
  if (process.env.GITHUB_ACTIONS === 'true') console.log(`::add-mask::${token}`);
  console.log(`Token minted for ${owner}.`);
}

mkdirSync(join(dir, 'bin'), { recursive: true, mode: 0o700 });
const file = join(dir, 'tokens.json');
writeFileSync(file, JSON.stringify(tokens), { mode: 0o600 });
chmodSync(file, 0o600);
// The real gh: the first on PATH that is not this wrapper. Minted again (tokens last an hour), the wrapper from the
// first mint is already first on PATH: taking it would make the wrapper exec itself, and every gh call hang.
let realGh = '';
try {
  realGh = execFileSync('bash', ['-c', 'type -ap gh'], { encoding: 'utf8' }).split('\n')
    .find((p) => p && resolve(p) !== join(dir, 'bin', 'gh')) || '';
} catch { /* no gh: only git is served */ }

writeFileSync(join(dir, 'bin', 'gh'), `#!/usr/bin/env bash
# Written by kheona-skill scripts/kskill-app-tokens.mjs: gh with the App token of the owner the command names.
owner_of() { local v=\${1#https://github.com/}; v=\${v#github.com/}; v=\${v#/}; v=\${v#repos/}; printf '%s' "\${v%%/*}"; }
owner="" args=("$@")
for ((i = 0; i < \${#args[@]}; i++)); do
  a=\${args[i]}
  case $a in
    -R|--repo) owner=$(owner_of "\${args[i+1]:-}") ;;
    --repo=*) owner=$(owner_of "\${a#--repo=}") ;;
    repos/*/*|/repos/*/*|https://github.com/*/*|github.com/*/*) owner=$(owner_of "$a") ;;
    *) if [ "\${args[0]:-}" = repo ] && [ "$i" -eq 2 ] && [[ $a =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then owner=\${a%%/*}; fi ;;
  esac
  [ -n "$owner" ] && break
done
[ -n "$owner" ] || owner=\${GH_REPO%%/*}
[ -n "$owner" ] || owner=$(owner_of "$(git remote get-url origin 2>/dev/null | sed 's#^git@github.com:#github.com/#')")
[ -n "$owner" ] || owner=\${GITHUB_REPOSITORY_OWNER:-}
token=$(jq -r --arg o "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" '.[$o] // empty' ${JSON.stringify(file)})
if [ -n "$token" ]; then export GH_TOKEN=$token; fi
exec ${JSON.stringify(realGh || 'gh')} "$@"
`, { mode: 0o700 });

writeFileSync(join(dir, 'bin', 'git-credential-kskill'), `#!/usr/bin/env bash
# Written by kheona-skill scripts/kskill-app-tokens.mjs: git credentials for https://github.com/<owner>/..., the
# App token of that owner. Needs credential.useHttpPath (set with the helper).
[ "\${1:-}" = get ] || exit 0
host="" path=""
while IFS='=' read -r k v; do [ -n "$k" ] || break; case $k in host) host=$v ;; path) path=$v ;; esac; done
[ "$host" = github.com ] || exit 0
owner=\${path%%/*}
token=$(jq -r --arg o "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" '.[$o] // empty' ${JSON.stringify(file)})
[ -n "$token" ] || exit 0
printf 'username=x-access-token\\npassword=%s\\n' "$token"
`, { mode: 0o700 });

if (install && process.env.GITHUB_ACTIONS === 'true') {
  appendFileSync(process.env.GITHUB_PATH, `${join(dir, 'bin')}\n`);
  appendFileSync(process.env.GITHUB_ENV, `KSKILL_APP_TOKENS=${file}\n`);
  const git = (...a) => execFileSync('git', ['config', '--global', ...a]);
  git('--replace-all', 'credential.https://github.com.helper', '');
  git('--add', 'credential.https://github.com.helper', join(dir, 'bin', 'git-credential-kskill'));
  git('credential.https://github.com.useHttpPath', 'true');
  // Every github.com remote over HTTPS, so the helper serves it (a submodule or a clone may name git@github.com:).
  git('url.https://github.com/.insteadOf', 'git@github.com:');
}
console.log(`Owners: ${Object.keys(tokens).join(', ')}. ${install ? 'gh and git now pick' : `${join(dir, 'bin')}/gh picks`} the token by owner.`);
