#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# kskill-app-tokens.mjs against a fake broker, OIDC endpoint and GitHub API (a local HTTP server): which endpoint
# each mode asks, and the tokens it writes per owner.
set -uo pipefail
unset GITHUB_ACTIONS
HERE=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d)
pass=0 failed=0
check() { if [[ $2 =~ $3 ]]; then pass=$((pass+1)); echo "ok   $1"; else failed=$((failed+1)); echo "FAIL $1 (got: $2)"; fi; }
cat > "$T/server.mjs" <<'JS'
import { createServer } from 'node:http';
import { appendFileSync, readFileSync } from 'node:fs';
const log = process.argv[2], parentFile = process.argv[3];
const server = createServer((req, res) => {
  let body = ''; req.on('data', (c) => { body += c; }); req.on('end', () => {
    appendFileSync(log, `${req.method} ${req.url.split('?')[0]} ${body}\n`);
    const send = (status, o) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
    if (req.url.startsWith('/oidc')) return send(200, { value: 'oidc' });
    if (req.url === '/broker/tokens') return send(403, { error: 'this repository may not work across owners' });
    if (req.url === '/broker/token') { const b = JSON.parse(body || '{}'); return send(200, { token: b.repository ? `tok-${b.repository}` : 'tok-self' }); }
    if (req.url.startsWith('/api/repos/')) { const p = readFileSync(parentFile, 'utf8').trim(); return send(200, p ? { parent: { full_name: p } } : {}); }
    send(404, {});
  });
});
server.listen(0, '127.0.0.1', () => console.log(server.address().port));
JS
: > "$T/parent"
node "$T/server.mjs" "$T/log" "$T/parent" > "$T/port" & SERVER=$!; disown
trap 'kill $SERVER 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
P=$(cat "$T/port")
run() { : > "$T/log"; rm -rf "$T/d"
  KSKILL_TOKEN_BROKER_URL="http://127.0.0.1:$P/broker" ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:$P/oidc?a=1" ACTIONS_ID_TOKEN_REQUEST_TOKEN=t \
    KSKILL_GITHUB_API="http://127.0.0.1:$P/api" GITHUB_REPOSITORY=Org/app node "$HERE/.github/scripts/kskill-app-tokens.mjs" "$T/d" "$@" 2>&1; }

out=$(run); rc=$?
check "every owner: refused by the broker, exit 1" "$rc" '^1$'
check "... saying why" "$out" 'HTTP 403 this repository may not work across owners'
out=$(run --self); rc=$?
check "--self, not a fork: exit 0" "$rc" '^0$'
check "... asks /token only" "$(grep -c '/broker/tokens' "$T/log") $(grep -c '/broker/token ' "$T/log")" '^0 1$'
check "... one token, this owner's" "$(cat "$T/d/tokens.json")" '^\{"org":"tok-self"\}$'
echo 'Parent/app' > "$T/parent"
out=$(run --self); rc=$?
check "--self, a fork: exit 0" "$rc" '^0$'
check "... asks /token for the parent by name" "$(grep '/broker/token ' "$T/log" | tail -1)" '"repository":"Parent/app"'
check "... a token per owner" "$(cat "$T/d/tokens.json")" '^\{"org":"tok-self","parent":"tok-Parent/app"\}$'
echo 'Org/template' > "$T/parent"
out=$(run --self); rc=$?
check "--self, a parent of the same owner: one token, a warning" "$rc $(cat "$T/d/tokens.json")" '^0 \{"org":"tok-self"\}$'
check "... the warning" "$out" 'has this repository.s owner'

echo "app-tokens: $pass passed, $failed failed"
[ "$failed" = 0 ]
