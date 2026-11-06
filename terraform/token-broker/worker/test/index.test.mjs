// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
// not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, createSign } from 'node:crypto';
import { handle, decide } from '../index.mjs';

const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const app = generateKeyPairSync('rsa', { modulusLength: 2048 });
const now = 2_000_000_000;
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const claims = { iss: 'https://token.actions.githubusercontent.com', aud: 'kskill-token-broker', exp: now + 300, repository: 'owner/repo', repository_owner: 'owner', job_workflow_ref: 'owner/kheona-skill/.github/workflows/kskill-pr.yml@refs/tags/v1.0.0' };
const oidc = (over = {}, key = privateKey) => {
  const unsigned = `${b64({ alg: 'RS256', kid: 'k' })}.${b64({ ...claims, ...over })}`;
  return `${unsigned}.${createSign('RSA-SHA256').update(unsigned).sign(key, 'base64url')}`;
};
const policy = { workflowRepositories: ['owner/kheona-skill'], owners: ['owner'], maxPermissions: { contents: 'write', pull_requests: 'write' }, shared: { owner: ['owner/library'] }, acrossOwners: ['owner/runner'] };
const env = { POLICY: JSON.stringify(policy), KSKILL_APP_ID: '1', KSKILL_APP_PRIVATE_KEY: app.privateKey.export({ type: 'pkcs8', format: 'pem' }) };
const calls = [];
const fake = async (url, init = {}) => {
  calls.push([init.method || 'GET', url, init.body]);
  const u = String(url);
  const ok = (o) => new Response(JSON.stringify(o), { status: 200 });
  if (u.endsWith('/.well-known/jwks')) return ok({ keys: [{ ...publicKey.export({ format: 'jwk' }), kid: 'k', alg: 'RS256' }] });
  if (u.includes('/app/installations?')) return ok([{ id: 7, account: { login: 'Owner' } }]);
  if (u.endsWith('/access_tokens')) return ok({ token: 'minted', expires_at: 'later' });
  if (u.endsWith('/installation')) return ok({ id: 7 });
  if (u.endsWith('/repos/owner/repo')) return ok({ parent: { full_name: 'upstream/repo' } });
  return new Response('{}', { status: 404 });
};
const ask = (path, token, body) => handle(new Request(`https://broker.example.com${path}`, { method: 'POST', headers: { authorization: `Bearer ${token}` }, body: JSON.stringify(body ?? {}) }), env, fake, now);

test('a shared workflow gets a token for its own repository alone', async () => {
  calls.length = 0;
  const r = await ask('/token', oidc(), { permissions: { contents: 'read' } });
  assert.equal(r.status, 200);
  assert.equal((await r.json()).token, 'minted');
  assert.deepEqual(JSON.parse(calls.at(-1)[2]), { repositories: ['repo'], permissions: { contents: 'read' } });
});
test('a bad signature, audience or expiry is refused', async () => {
  const other = generateKeyPairSync('rsa', { modulusLength: 2048 });
  assert.equal((await ask('/token', oidc({}, other.privateKey))).status, 401);
  assert.equal((await ask('/token', oidc({ aud: 'x' }))).status, 401);
  assert.equal((await ask('/token', oidc({ exp: now - 1 }))).status, 401);
});
test('a job not running a shared workflow is refused', async () => {
  assert.equal((await ask('/token', oidc({ job_workflow_ref: 'owner/repo/.github/workflows/mine.yml@refs/heads/main' }))).status, 403);
  assert.equal((await ask('/token', oidc({ job_workflow_ref: undefined }))).status, 403);
});
test('an unknown owner is refused', async () => {
  assert.equal((await ask('/token', oidc({ repository_owner: 'stranger', repository: 'stranger/repo' }))).status, 403);
});
test('a permission beyond the policy is refused, a level beyond it clamped', () => {
  assert.throws(() => decide(claims, { permissions: { administration: 'write' } }, policy), /administration/);
  assert.deepEqual(decide(claims, { permissions: { contents: 'admin' } }, policy).permissions, { contents: 'write' });
});
test('shared: read-only, from the policy', async () => {
  calls.length = 0;
  const r = await ask('/token', oidc(), { shared: true });
  assert.equal(r.status, 200);
  assert.deepEqual(JSON.parse(calls.at(-1)[2]), { repositories: ['library'], permissions: { contents: 'read' } });
});
test("another repository only as this fork's parent", async () => {
  assert.equal((await ask('/token', oidc(), { repository: 'upstream/repo' })).status, 200);
  assert.equal((await ask('/token', oidc(), { repository: 'someone/else' })).status, 403);
});
test('/tokens only from a listed repository', async () => {
  assert.equal((await ask('/tokens', oidc())).status, 403);
  const r = await ask('/tokens', oidc({ repository: 'owner/runner' }));
  assert.deepEqual(await r.json(), { tokens: { owner: 'minted' } });
});
test('a key that is not PKCS#8 fails closed and says nothing of it', async () => {
  const r = await handle(new Request('https://b/token', { method: 'POST', headers: { authorization: `Bearer ${oidc()}` } }), { ...env, KSKILL_APP_PRIVATE_KEY: '-----BEGIN RSA PRIVATE KEY-----' }, fake, now);
  assert.equal(r.status, 500);
});
test('GET and other paths: 404', async () => {
  assert.equal((await handle(new Request('https://b/token'), env, fake, now)).status, 404);
});
