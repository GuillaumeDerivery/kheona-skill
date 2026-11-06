// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
// not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// the deterministic half of the inbox's sentry-triage job (.github/workflows/kskill-inbox.yml): reads
// this repository's own Sentry project with its own token, keeps Sentry in step with GitHub, and decides nothing a
// model should.
//
//   node kskill-sentry-triage.mjs collect --out DIR/sentry.json   every unresolved issue of the project (90 days, all
//                                 pages), each with the GitHub issues and PRs already naming it, and the latest event
//                                 of every new one; then Sentry follows GitHub (below)
//   node kskill-sentry-triage.mjs result --dir DIR [--run-url U]  DIR/sentry.json + DIR/triage.json (Claude's) ->
//                                 DIR/result.json, the run's outcome the Kheona doctor reads; printed as a summary
//
// collect reads SENTRY_ORG, SENTRY_PROJECT, SENTRY_URL (default https://sentry.io), SENTRY_AUTH_TOKEN, GITHUB_REPOSITORY,
// and GH_TOKEN for `gh` (this repository's issues and PRs, and its parent's when it is a fork). Its `status`:
//   collected        the list is there (`issues`, `priority`: the new ones by users affected, then events)
//   token-error      Sentry refused the token (401/403: a token without event:read, event:write, project:read, org:read, such as
//                    an org auth token made for symbol uploads): {"error": "token cannot read issues", "httpStatus": 403}
//   not-configured   a variable or the token is missing (`missing` names them, never a value)
//   error            Sentry unreachable or another HTTP error (`error`)
// It always exits 0 with the file written, so the run stays green and the doctor reports the status per repository.
// Never prints the token.
//
// Sentry follows GitHub . An unresolved Sentry issue whose
// every GitHub issue naming it is closed (and at least one names it) is updated in Sentry, with a comment linking it:
//   closed as fixed, and a merged PR names it    resolved in the next release (main ships at the next prod release)
//   closed as fixed, no PR (config, infra, data) resolved
//   closed as noise (label sentry-noise) or not planned   ignored until it escalates
// Sentry reopens a resolved issue itself when it comes back (`substatus: regressed`) and an ignored one when it
// escalates: only then is the issue `regressed` here, and its GitHub issue reopened by the triage (noise: only when it
// escalates; a regressed noise issue is ignored again). `reconciled` lists
// each update; a token Sentry refuses to write with (it needs event:write) stops them: `writeStatus: token-cannot-write`.
// `fixQueue`: open GitHub issues labelled `sentry: fix deferred`, a real issue whose fix PR a run had no room for.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [cmd, ...rest] = process.argv.slice(2);
const opt = (name, dflt) => { const i = rest.indexOf(name); return i >= 0 ? rest[i + 1] : dflt; };
const PAGE = 100;
const MAX_PAGES = 20;
const DEFERRED = 'sentry: fix deferred';
const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'));

class SentryError extends Error { constructor(status, path) { super(`Sentry answered HTTP ${status} for ${path}`); this.status = status; } }
async function sentryRaw(base, token, path, { method = 'GET', body } = {}) {
  const res = await fetch(`${base.replace(/\/$/, '')}/api/0/${path}`, { method,
    headers: { Authorization: `Bearer ${token}`, ...(body ? { 'content-type': 'application/json' } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}) });
  if (!res.ok) throw new SentryError(res.status, path.split('?')[0]);
  return res;
}
const sentry = async (base, token, path, o) => (await sentryRaw(base, token, path, o)).json();
// Every page of a list: Sentry's Link header carries `rel="next"; results="true"; cursor="..."` while more remain.
async function sentryAll(base, token, path) {
  const all = [];
  let cursor = null;
  for (let page = 0; page < MAX_PAGES; page++) {
    const res = await sentryRaw(base, token, `${path}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`);
    all.push(...(await res.json()));
    const next = (res.headers.get('link') || '').split(',').find((l) => /rel="next"/.test(l) && /results="true"/.test(l));
    cursor = next?.match(/cursor="([^"]+)"/)?.[1] || null;
    if (!cursor) break;
  }
  return all;
}

// The latest event, reduced to what classifies it (environment, release, device) and locates the cause.
function trimEvent(e) {
  const tag = (k) => (e.tags || []).find((t) => t.key === k)?.value ?? null;
  const exc = (e.entries || []).find((x) => x.type === 'exception')?.data?.values || [];
  const last = exc.at(-1);
  const frames = (last?.stacktrace?.frames || []).filter((f) => f.inApp).slice(-6).reverse()
    .map((f) => `${f.filename || f.module || '?'}:${f.lineNo ?? '?'} ${f.function || ''}`.trim());
  const crumbs = (e.entries || []).find((x) => x.type === 'breadcrumbs')?.data?.values?.slice(-15) || [];
  return { at: e.dateCreated || null, environment: tag('environment'), release: tag('release') ?? e.release?.version ?? null,
    osBuild: tag('os.build'), device: tag('device') ?? e.contexts?.device?.model ?? null, os: tag('os') ?? e.contexts?.os?.name ?? null,
    user: !!e.user, exception: last ? `${last.type || ''}: ${last.value || ''}`.trim() : (e.title || null), frames,
    stack: exc.map((v) => ({ type: v.type, value: v.value,
      frames: (v.stacktrace?.frames || []).slice(-15).map((f) => ({ file: f.filename, line: f.lineNo, fn: f.function, inApp: f.inApp })) })),
    breadcrumbs: crumbs.map((b) => ({ at: b.timestamp, category: b.category, message: b.message, level: b.level })) };
}

const gh = (args) => execFileSync('gh', args, { encoding: 'utf8', maxBuffer: 256 << 20, stdio: ['ignore', 'pipe', 'pipe'] });
// Every issue and PR of a repository (state all): what names a Sentry issue already. null when unreadable.
function githubTexts(repo) {
  try {
    return JSON.parse(gh(['api', '--paginate', '--slurp', `repos/${repo}/issues?state=all&per_page=100`])).flat()
      .map((i) => ({ n: i.number, url: i.html_url, state: i.state, closedAt: i.closed_at || null, reason: i.state_reason || null,
        labels: (i.labels || []).map((l) => (typeof l === 'string' ? l : l.name)), pr: !!i.pull_request,
        merged: !!i.pull_request?.merged_at, text: `${i.title}\n${i.body || ''}` }));
  } catch { return null; }
}
function parentOf(repo) {
  try { return JSON.parse(gh(['api', `repos/${repo}`])).parent?.full_name || null; } catch { return null; }
}

// What Sentry should say about an issue GitHub has closed everywhere: the Sentry update and its comment.
function follow(tickets, known) {
  const noise = tickets.some((k) => (k.labels || []).includes('sentry-noise')) || tickets.every((k) => k.reason === 'not_planned');
  const issue = tickets.find((k) => (k.labels || []).includes('sentry-noise'))?.url || tickets[0].url;
  if (noise) return { op: 'ignored', issue, body: { status: 'ignored', substatus: 'archived_until_escalating', statusDetails: {} },
    note: `Ignored until it escalates: closed on GitHub as noise or not planned, ${issue} (Kheona triage).` };
  const pr = known.find((k) => k.pr && k.merged);
  if (pr) return { op: 'resolved', issue, pr: pr.url, body: { status: 'resolved', statusDetails: { inNextRelease: true } },
    note: `Resolved in the next release: fixed by ${pr.url}, tracked in ${issue} (Kheona triage).` };
  return { op: 'resolved', issue, body: { status: 'resolved', statusDetails: {} },
    note: `Resolved: closed on GitHub as fixed without a PR, ${issue} (Kheona triage).` };
}

async function collect() {
  const file = opt('--out', 'sentry.json');
  const { SENTRY_ORG: org, SENTRY_PROJECT: project, SENTRY_AUTH_TOKEN: token, GITHUB_REPOSITORY: repo } = process.env;
  const region = process.env.SENTRY_URL || 'https://sentry.io';
  const out = { date: new Date().toISOString(), repo: repo || null, parent: null, org: org || null, project: project || null, region,
    status: 'collected', issues: [], priority: [], fixQueue: [], reconciled: [] };
  const done = () => {
    writeFileSync(file, JSON.stringify(out, null, 2));
    const n = out.priority.length;
    const done2 = (op) => out.reconciled.filter((r) => r.op === op).length;
    console.log(out.status === 'collected' ? `Sentry ${org}/${project}: ${out.issues.length} unresolved issue(s), ${n} that no GitHub issue names yet, ${out.fixQueue.length} waiting for a fix PR; in Sentry ${done2('resolved')} resolved, ${done2('ignored')} ignored${out.writeStatus ? ` (${out.writeStatus}: SENTRY_AUTH_TOKEN needs event:write)` : ''}`
      : `Sentry ${org || '?'}/${project || '?'}: ${out.status}${out.error ? `: ${out.error}` : ''}${out.missing ? ` (${out.missing.join(', ')})` : ''}`);
  };
  const missing = Object.entries({ SENTRY_ORG: org, SENTRY_PROJECT: project, SENTRY_AUTH_TOKEN: token }).filter(([, v]) => !v).map(([k]) => k);
  if (missing.length) { Object.assign(out, { status: 'not-configured', missing }); return done(); }
  out.parent = repo ? parentOf(repo) : null;
  let list;
  try {
    list = await sentryAll(region, token, `projects/${org}/${project}/issues/?query=${encodeURIComponent('is:unresolved lastSeen:-90d')}&limit=${PAGE}`);
  } catch (e) {
    if (e.status === 401 || e.status === 403) Object.assign(out, { status: 'token-error', error: 'token cannot read issues', httpStatus: e.status });
    else Object.assign(out, { status: 'error', error: e.message, ...(e.status ? { httpStatus: e.status } : {}) });
    return done();
  }
  const sources = [repo, out.parent].filter(Boolean).map((x) => ({ repo: x, items: githubTexts(x) }));
  if (sources.some((g) => g.items === null)) out.warning = 'GitHub issues unreadable: every Sentry issue is listed as new';
  for (const i of list) {
    const known = sources.flatMap((g) => (g.items || []).filter((t) => t.text.includes(i.shortId) || t.text.includes(`/issues/${i.id}/`) || (i.permalink && t.text.includes(i.permalink)))
      .map((t) => ({ repo: g.repo, n: t.n, url: t.url, state: t.state, closedAt: t.closedAt, reason: t.reason, labels: t.labels, pr: t.pr, merged: t.merged })));
    const issue = { id: i.id, shortId: i.shortId, url: i.permalink, title: i.title, culprit: i.culprit || null, level: i.level,
      substatus: i.substatus || null, users: Number(i.userCount || 0), events: Number(i.count || 0), firstSeen: i.firstSeen,
      lastSeen: i.lastSeen, known };
    const tickets = known.filter((k) => !k.pr);
    const closed = tickets.length > 0 && tickets.every((k) => k.state === 'closed');
    // Back after Sentry itself had it resolved or ignored: the triage reopens its GitHub issue. Noise is never back for
    // a regression (a pre-launch robot or a probe fires again by nature, and re-triaging it would loop every day): it is
    // ignored, and only an ignored one that escalates comes back.
    const noise = tickets.some((k) => (k.labels || []).includes('sentry-noise'));
    const back = closed && (issue.substatus === 'escalating' || (issue.substatus === 'regressed' && !noise));
    if (!known.length || back) {
      if (back) issue.regressed = true;
      issue.event = await sentry(region, token, `organizations/${org}/issues/${i.id}/events/latest/`).then(trimEvent, (e) => ({ error: e.message }));
    } else if (closed) issue.follow = follow(tickets, known);
    const queued = tickets.find((k) => k.state === 'open' && (k.labels || []).includes(DEFERRED));
    if (queued) out.fixQueue.push({ shortId: i.shortId, url: i.permalink, users: issue.users, events: issue.events, issue: queued.url, repo: queued.repo, n: queued.n });
    out.issues.push(issue);
  }
  // Sentry follows GitHub: each closed one updated once, with a comment naming what closed it.
  for (const i of out.issues.filter((x) => x.follow)) {
    const f = i.follow;
    const rec = { shortId: i.shortId, url: i.url, op: f.op, issue: f.issue, ...(f.pr ? { pr: f.pr } : {}) };
    if (out.writeStatus) { out.reconciled.push({ ...rec, op: 'skipped' }); continue; }
    try {
      await sentry(region, token, `organizations/${org}/issues/${i.id}/`, { method: 'PUT', body: f.body });
      await sentry(region, token, `organizations/${org}/issues/${i.id}/comments/`, { method: 'POST', body: { text: f.note } }).catch(() => null);
      out.reconciled.push(rec);
    } catch (e) {
      if (e.status === 401 || e.status === 403) out.writeStatus = 'token-cannot-write';
      out.reconciled.push({ ...rec, op: e.status === 401 || e.status === 403 ? 'skipped' : 'failed', error: e.message });
    }
  }
  out.fixQueue.sort((a, b) => b.users - a.users || b.events - a.events || a.shortId.localeCompare(b.shortId));
  out.priority = out.issues.filter((i) => !i.known.length || i.regressed)
    .map((i) => ({ shortId: i.shortId, users: i.users, events: i.events, url: i.url, ...(i.regressed ? { regressed: true } : {}) }))
    .sort((a, b) => b.users - a.users || b.events - a.events || a.shortId.localeCompare(b.shortId));
  return done();
}

// The run's outcome: what the doctor reports per repository and the map shows. triage.json is Claude's record
// ({"handled": [{shortId, bucket: real|noise|unverified, op, issue, pr, repo, why}], "deferred": [shortId]}); absent
// when no triage ran (nothing new, a token error, or Claude Code failed).
function result() {
  const dir = opt('--dir', '.');
  const s = existsSync(join(dir, 'sentry.json')) ? readJson(join(dir, 'sentry.json')) : { status: 'error', error: 'collect wrote nothing' };
  const t = (() => {
    try { return existsSync(join(dir, 'triage.json')) ? readJson(join(dir, 'triage.json')) : null; } catch { return { error: 'triage.json unreadable' }; }
  })();
  const handled = Array.isArray(t?.handled) ? t.handled : [];
  const count = (f) => handled.filter(f).length;
  const r = { date: s.date || null, repo: s.repo || process.env.GITHUB_REPOSITORY || null, parent: s.parent || null, org: s.org || null,
    project: s.project || null, region: s.region || null, runUrl: opt('--run-url', null), status: s.status,
    ...(s.error ? { error: s.error } : {}), ...(s.httpStatus ? { httpStatus: s.httpStatus } : {}), ...(s.missing ? { missing: s.missing } : {}),
    ...(s.warning ? { warning: s.warning } : {}),
    collected: (s.issues || []).length, new: (s.priority || []).length,
    triage: s.status !== 'collected' || !((s.priority || []).length + (s.fixQueue || []).length) ? 'none' : t ? (t.error ? 'failed' : 'done') : (process.env.TRIAGE_SKIPPED || 'failed'),
    created: count((h) => h.op === 'created'), updated: count((h) => h.op === 'updated' || h.op === 'reopened'),
    noise: count((h) => h.bucket === 'noise'), prs: count((h) => !!h.pr), deferred: Array.isArray(t?.deferred) ? t.deferred.length : 0,
    fixQueue: (s.fixQueue || []).length,
    resolved: (s.reconciled || []).filter((x) => x.op === 'resolved').length, ignored: (s.reconciled || []).filter((x) => x.op === 'ignored').length,
    ...(s.writeStatus ? { writeStatus: s.writeStatus } : {}), reconciled: s.reconciled || [],
    handled: handled.map((h) => ({ ...h, ...(() => { const i = (s.issues || []).find((x) => x.shortId === h.shortId); return i ? { url: i.url, users: i.users, events: i.events } : {}; })() })) };
  writeFileSync(join(dir, 'result.json'), JSON.stringify(r, null, 2));
  const head = r.status === 'collected'
    ? `${r.repo}: collected ${r.collected} (${r.new} new): ${r.created} issue(s) created, ${r.updated} updated, ${r.noise} noise, ${r.prs} fix PR(s), ${r.deferred} deferred, ${r.fixQueue} waiting for a fix PR (triage ${r.triage}); Sentry: ${r.resolved} resolved, ${r.ignored} ignored${r.writeStatus ? ' (token cannot write: SENTRY_AUTH_TOKEN needs event:write)' : ''}`
    : r.status === 'token-error' ? `${r.repo}: token cannot read issues (HTTP ${r.httpStatus}): SENTRY_AUTH_TOKEN needs event:read, event:write, project:read, org:read`
      : `${r.repo}: ${r.status}${r.error ? `: ${r.error}` : ''}${r.missing ? `: ${r.missing.join(', ')} not set` : ''}`;
  console.log(head);
  for (const h of r.handled) console.log(`- ${h.shortId} ${h.bucket} ${h.op || ''} ${h.issue || ''} ${h.pr || ''}${h.why ? ` (${h.why})` : ''}`.replace(/\s+/g, ' ').trim());
  for (const x of r.reconciled) console.log(`- ${x.shortId} Sentry ${x.op} ${x.issue || ''} ${x.pr || ''}${x.error ? ` (${x.error})` : ''}`.replace(/\s+/g, ' ').trim());
}

if (cmd === 'collect') await collect();
else if (cmd === 'result') result();
else { console.error('usage: kskill-sentry-triage.mjs {collect --out FILE | result --dir DIR [--run-url U]}'); process.exit(64); }
