// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
// not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// The token broker: exchanges a GitHub Actions OIDC identity for a short-lived GitHub App token, so no App key reaches a
// repository. It copies nothing and stores nothing: it verifies, decides from POLICY, and mints.
//
// POST /token   Authorization: Bearer <OIDC token>, body {repository?, shared?, permissions?}  -> {token, expiresAt}
// POST /tokens  Authorization: Bearer <OIDC token>  -> {tokens: {"<owner>": "<token>"}}  (one per installation, policy.acrossOwners only)
//
// Env: POLICY (JSON, below), KSKILL_APP_ID, KSKILL_APP_PRIVATE_KEY (PKCS#8 PEM, a Worker secret, never in Terraform).
// POLICY: {
//   "workflowRepositories": ["owner/kheona-skill"],   a token only for a job running one of these repositories' workflows
//   "owners": ["owner"],                              repositories asking must belong to one of these
//   "audience": "kskill-token-broker",
//   "maxPermissions": {"contents": "write", ...},     the ceiling; a request is clamped to it
//   "shared": {"owner": ["owner/library"]},           read-only repositories per asking owner
//   "acrossOwners": ["owner/runner"]                  repositories allowed to ask POST /tokens
// }
const ISSUER = 'https://token.actions.githubusercontent.com';
const API = 'https://api.github.com';
const LEVELS = { read: 1, write: 2, admin: 3 };

const b64url = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const fromB64url = (s) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
class Refused extends Error { constructor(status, message) { super(message); this.status = status; } }

export async function verifyOidc(token, audience, now, fetchImpl) {
  const parts = token.split('.');
  if (parts.length !== 3) throw new Refused(401, 'not a JWT');
  const header = JSON.parse(new TextDecoder().decode(fromB64url(parts[0])));
  const claims = JSON.parse(new TextDecoder().decode(fromB64url(parts[1])));
  if (header.alg !== 'RS256') throw new Refused(401, 'unexpected algorithm');
  const { keys } = await (await fetchImpl(`${ISSUER}/.well-known/jwks`)).json();
  const jwk = keys.find((k) => k.kid === header.kid);
  if (!jwk) throw new Refused(401, 'unknown key');
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, fromB64url(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  if (!ok) throw new Refused(401, 'bad signature');
  if (claims.iss !== ISSUER) throw new Refused(401, 'wrong issuer');
  if (claims.aud !== audience) throw new Refused(401, 'wrong audience');
  if (!(claims.exp > now) || claims.nbf > now + 60) throw new Refused(401, 'expired');
  return claims;
}

export function decide(claims, body, policy) {
  const owner = String(claims.repository_owner || '').toLowerCase();
  if (!(policy.owners || []).map((o) => o.toLowerCase()).includes(owner)) throw new Refused(403, 'owner not allowed');
  const runs = String(claims.job_workflow_ref || '').toLowerCase();
  if (!(policy.workflowRepositories || []).some((r) => runs.startsWith(`${r.toLowerCase()}/.github/workflows/`))) throw new Refused(403, 'not a shared workflow');
  if (body.shared) {
    const repositories = policy.shared?.[owner] ?? policy.shared?.[claims.repository_owner] ?? [];
    if (!repositories.length) throw new Refused(403, 'nothing shared with this owner');
    return { repositories, permissions: { contents: 'read' } };
  }
  const permissions = {};
  for (const [k, v] of Object.entries(body.permissions || policy.maxPermissions || {})) {
    const max = policy.maxPermissions?.[k];
    if (!max || !LEVELS[v]) throw new Refused(403, `permission ${k} not allowed`);
    permissions[k] = LEVELS[v] > LEVELS[max] ? max : v;
  }
  return { repositories: [body.repository || claims.repository], permissions, parentOf: body.repository && body.repository.toLowerCase() !== claims.repository.toLowerCase() ? claims.repository : null };
}

async function appJwt(env, now) {
  const pem = env.KSKILL_APP_PRIVATE_KEY || '';
  if (!pem.includes('BEGIN PRIVATE KEY')) throw new Refused(500, 'the App key must be PKCS#8');
  const der = fromB64url(pem.replace(/-----[^-]+-----/g, '').replace(/\s/g, '').replace(/\+/g, '-').replace(/\//g, '_'));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const enc = (o) => b64url(new TextEncoder().encode(JSON.stringify(o)));
  const unsigned = `${enc({ alg: 'RS256', typ: 'JWT' })}.${enc({ iat: now - 60, exp: now + 540, iss: env.KSKILL_APP_ID })}`;
  return `${unsigned}.${b64url(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned)))}`;
}

async function gh(fetchImpl, path, token, init = {}) {
  const r = await fetchImpl(`${API}${path}`, { ...init, headers: { accept: 'application/vnd.github+json', authorization: `Bearer ${token}`, 'user-agent': 'kskill-token-broker', 'x-github-api-version': '2022-11-28' } });
  if (!r.ok) throw new Refused(r.status === 404 ? 403 : 502, `GitHub ${r.status} on ${init.method || 'GET'} ${path.split('?')[0]}`);
  return r.json();
}

export async function handle(request, env, fetchImpl = fetch, now = Math.floor(Date.now() / 1000)) {
  try {
    const { pathname } = new URL(request.url);
    if (request.method !== 'POST' || !['/token', '/tokens'].includes(pathname)) return json(404, { error: 'not found' });
    const policy = JSON.parse(env.POLICY);
    const bearer = (request.headers.get('authorization') || '').replace(/^Bearer /, '');
    if (!bearer) throw new Refused(401, 'no identity');
    const claims = await verifyOidc(bearer, policy.audience || 'kskill-token-broker', now, fetchImpl);
    const jwt = await appJwt(env, now);
    if (pathname === '/tokens') {
      decide(claims, {}, { ...policy, maxPermissions: {} });
      if (!(policy.acrossOwners || []).map((r) => r.toLowerCase()).includes(claims.repository.toLowerCase())) throw new Refused(403, 'this repository may not work across owners');
      const tokens = {};
      for (const i of await gh(fetchImpl, '/app/installations?per_page=100', jwt)) {
        tokens[i.account.login.toLowerCase()] = (await gh(fetchImpl, `/app/installations/${i.id}/access_tokens`, jwt, { method: 'POST' })).token;
      }
      return json(200, { tokens });
    }
    const body = await request.json().catch(() => ({}));
    const grant = decide(claims, body, policy);
    if (grant.parentOf) {
      const asking = await gh(fetchImpl, `/repos/${grant.parentOf}/installation`, jwt);
      const own = await gh(fetchImpl, `/app/installations/${asking.id}/access_tokens`, jwt, { method: 'POST', body: JSON.stringify({ repositories: [grant.parentOf.split('/')[1]], permissions: { metadata: 'read' } }) });
      const repo = await gh(fetchImpl, `/repos/${grant.parentOf}`, own.token);
      if ((repo.parent?.full_name || '').toLowerCase() !== grant.repositories[0].toLowerCase()) throw new Refused(403, 'not this repository\'s parent');
    }
    const [target] = grant.repositories;
    const installation = await gh(fetchImpl, `/repos/${target}/installation`, jwt);
    const minted = await gh(fetchImpl, `/app/installations/${installation.id}/access_tokens`, jwt, { method: 'POST', body: JSON.stringify({ repositories: grant.repositories.map((r) => r.split('/')[1]), permissions: grant.permissions }) });
    return json(200, { token: minted.token, expiresAt: minted.expires_at });
  } catch (e) {
    return json(e.status || 500, { error: e.status ? e.message : 'internal error' });
  }
}

export default { fetch: (request, env) => handle(request, env) };
