#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# What a repository must carry, and its local rules. Runs from this version's files, never the repository's.
#
# Usage: kskill-repo-check.sh [--json] <repo-root> <this-repository-root>
#   --json prints one JSON document instead of the annotations, same exit code.
# Checks, in order:
#   1. the callers this repository needs are present and exactly what this version expects (scripts/kskill-callers.mjs);
#      .kheona.json is valid, renovate.json extends this repository's preset;
#   2. the inbox jobs this repository needs (for the doctor), listed in --json as `jobs`;
#   3. every other workflow file is declared in .kheona.json `workflows.local` with a reason;
#   4. no workflow reads `secrets.PAT`: a warning;
#   5. no tracked configuration holds a Sentry DSN: a warning, not in a Flutter repository;
#   6. a Flutter app reads build defines and dotenv only in lib/core/config/: a warning;
#   7. the local `.env` rules (off with `workflows.ci.skip.envFiles` and a reason);
#   8. git-crypt covers every secret file (off with `workflows.ci.skip.gitCrypt` and a reason);
#   9. no MongoDB connection string in the repository (off with `workflows.ci.skip.mongoUri` and a reason).
# Exit 1 on any failure.
# shellcheck disable=SC2016  # why: the single-quoted strings are jq programs; their $names are jq variables
set -uo pipefail
GRACE_DAYS=7
# Check 7 (the local .env) started on this day (UTC): its findings only warn for GRACE_DAYS after it.
ENV_SINCE=2026-10-27
# Check 8 (git-crypt covers every secret file): its findings only warn before this day (UTC), then fail.
GITCRYPT_FAILS=2026-11-10
# Check 9 (no committed MongoDB connection string): its findings only warn before this day (UTC), then fail.
MONGO_FAILS=2026-11-09

JSON=false
if [ "${1:-}" = --json ]; then JSON=true; shift; fi
REPO=${1:?usage: kskill-repo-check.sh [--json] <repo-root> <skill-root>}
SKILL=${2:?usage: kskill-repo-check.sh [--json] <repo-root> <skill-root>}
REPO=$(cd "$REPO" && pwd) || exit 64
SKILL=$(cd "$SKILL" && pwd) || exit 64
FAIL=0
# Every result is also a JSON record, one per line, assembled at the end for --json.
EVENTS=$(mktemp); trap 'rm -f "$EVENTS"' EXIT
rec() { jq -nc "$@" >> "$EVENTS"; }
gh_out() { # GitHub annotation in Actions, plain text elsewhere, nothing in --json mode
  local level=$1 file=$2 msg=$3
  [ "$JSON" = true ] && return 0
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::$level file=$file::$msg"; else echo "$level: $file: $msg"; fi
}
fail() { gh_out error "$1" "$2"; rec --arg f "$1" --arg m "$2" '{kind: "error", file: $f, message: $m}'; FAIL=1; }
warn() { gh_out warning "$1" "$2"; rec --arg f "$1" --arg m "$2" '{kind: "warning", file: $f, message: $m}'; }
copy() { # copy <path> <template or empty> <status> <blob>
  rec --arg p "$1" --arg t "$2" --arg s "$3" --arg b "$4" '{kind: "copy", path: $p, template: (if $t == "" then null else $t end), status: $s, blob: $b}'
}

CFG="$REPO/.kheona.json"
# not `// empty`: jq's `//` treats false as missing, which would make every `enabled: false` unreadable
cfg() { [ -f "$CFG" ] && jq -r "$1 | if . == null then empty else . end" "$CFG" 2>/dev/null; }
if [ ! -f "$CFG" ]; then rec '{kind: "kheona", state: "absent"}'
elif jq empty "$CFG" 2>/dev/null; then rec '{kind: "kheona", state: "valid"}'
else rec '{kind: "kheona", state: "invalid"}'; fail .kheona.json "not valid JSON"; fi

cd "$REPO" || exit 64
NOW=$(date +%s)
skipped() { [ -n "$(cfg ".workflows.ci.skip.$1")" ]; }
role=$(cfg .role)
stack=""
[ -f package.json ] && stack=node
{ [ -f Pipfile ] || [ -f pyproject.toml ]; } && stack=python
[ -f pubspec.yaml ] && stack=flutter

# 1. The callers, the settings' Renovate preset.
callers=$(node "$SKILL/scripts/kskill-callers.mjs" check --repo "$REPO" --json) || true
while IFS=$'\t' read -r path message; do
  [ -n "$path" ] || continue
  rec --arg p "$path" --arg m "$message" '{kind: "callers", path: $p, message: $m}'
  fail "$path" "$message"
done < <(jq -r '.problems[]? | [.path, .message] | @tsv' <<<"$callers")
SHIPS=$(jq -r '.ships // false' <<<"$callers")
if [ -n "$stack" ] || [ "$role" = infra ]; then
  if [ "${KSKILL_FORK:-false}" != true ] && { [ ! -f renovate.json ] || ! grep -q "/kheona-skill//renovate/" renovate.json; }; then
    fail renovate.json "must extend this repository's Renovate preset"
  fi
fi

# 2. The inbox jobs this repository needs.
JOBS=()
if [ -n "$stack" ]; then
  fork=${KSKILL_FORK:-false}
  [ "$fork" != true ] && grep -qE "url *= *.*[/:]${KSKILL_LIB_REPO:-none/none}(\.git)?$" .gitmodules 2>/dev/null && JOBS+=(bump-lib)
  [ "$fork" = true ] && JOBS+=(sync-upstream)
  [ -n "${KSKILL_SENTRY_PROJECT:-}" ] && JOBS+=(sentry-triage)
  [ "$stack" = node ] && [ -n "$(cfg .workflows.mutation)" ] && JOBS+=(mutation)
  [ "$stack" = flutter ] && [ "$fork" != true ] && [ "$(cfg .workflows.refreshFlutter.enabled)" != false ] && JOBS+=(refresh-flutter)
  [ "$stack" = flutter ] && JOBS+=(security-scan)
  [ "$SHIPS" = true ] && JOBS+=(release-pr)
fi
for j in ${JOBS[@]+"${JOBS[@]}"}; do rec --arg j "$j" '{kind: "job", job: $j}'; done
# 3. Workflows that are not templates are declared, with a reason.
while IFS= read -r w; do
  b=$(basename "$w")
  case "$b" in kskill-*) continue ;; esac
  reason=$(cfg ".workflows.local[\"$b\"]")
  if [ -z "$reason" ]; then
    rec --arg p "$w" '{kind: "undeclared", path: $p}'
    fail "$w" "not a kheona-skill caller: replace it with the workflow that does this job, or declare it in .kheona.json workflows.local {\"$b\": \"<why it is specific to this repository>\"}"
  elif [ "$role" = library ] && [ -f "$SKILL/scripts/kskill-workflow-definition.sh" ] && ! missing=$(bash "$SKILL/scripts/kskill-workflow-definition.sh" "$w"); then
    # A library's own workflows are in the map's catalog: each card shows its definition.
    warn "$w" "no definition for the map: ${missing//$'\n'/; } (# Trigger: / # Purpose: / # Effect: at the top of its leading comment, scripts/kskill-workflow-definition.sh)"
  fi
done < <(find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sed 's|^\./||' | sort)

# 4. The PAT is retired: a workflow still reading it warns (a copy: the sync updates it; a local one: a person).
while IFS= read -r w; do
  rec --arg p "$w" '{kind: "pat", path: $p}'
  warn "$w" "reads secrets.PAT, retired: use the automation App's token (actions/create-github-app-token with KSKILL_TOKEN_BROKER_URL)"
done < <(grep -lE 'secrets\.PAT([^A-Za-z0-9_]|$)' .github/workflows/*.yml .github/workflows/*.yaml 2>/dev/null | sort)

# 5. a backend's Sentry DSN should come from the deployment's Kubernetes Secret (best practice; committed still
# works). Files whose path has a `config/` directory or whose name says monitoring or sentry, as tracked by git (all
# files outside git); only those on disk are read (a sparse clone holds just these). A warning, reported by the map as
# . A Flutter app may commit its DSN (a compile-time constant, in the binary anyway): no check for stack flutter.
DSN_RE='https://[0-9a-f]{16,}@[A-Za-z0-9.-]*sentry\.io/[0-9]+'
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then tracked() { git ls-files; }; else tracked() { find . -type f -not -path './.git/*' | sed 's|^\./||'; }; fi
while IFS= read -r f; do
  if [ ! -f "$f" ] || ! grep -qIE "$DSN_RE" "$f" 2>/dev/null; then continue; fi
  rec --arg p "$f" '{kind: "dsn", path: $p}'
  warn "$f" "holds a Sentry DSN: best practice is the deployment's Kubernetes Secret. Declare the key empty and set it from the Secret (committed still works)"
done < <([ "$stack" = flutter ] || tracked | grep -iE '(^|/)config/|(^|/)[^/]*(monitoring|sentry)[^/]*$' | sort)

# 6. Flutter: the app's configuration is static consts in lib/core/config/; nothing else reads a build define or dotenv.
if [ "$stack" = flutter ]; then
  while IFS= read -r f; do
    if [ ! -f "$f" ] || ! grep -qE '(String|bool|int)\.fromEnvironment\(|dotenv' "$f" 2>/dev/null; then continue; fi
    rec --arg p "$f" '{kind: "config", path: $p}'
    warn "$f" "reads a build-time define or dotenv outside lib/core/config/: app configuration is a static const in lib/core/config/app_config.dart, imported from there"
  done < <(tracked | grep -E '^lib/.*\.dart$' | grep -v '^lib/core/config/' | sort)
fi

# 7. local runs read a gitignored .env described by a committed .env.example; no other .env* file holds real
# values (staging and production values live in the cluster's ConfigMap and Secret). and
if [ -z "$(cfg .workflows.ci.skip.envFiles)" ]; then
  env_since=$(jq -n --arg d "$ENV_SINCE" '$d + "T00:00:00Z" | fromdateiso8601')
  env_fails=$(jq -nr --argjson s "$((env_since + GRACE_DAYS * 86400))" '$s | todate | .[:10]')
  env_bad() { # env_bad <file> <message>
    rec --arg p "$1" --arg m "$2" '{kind: "env", path: $p, message: $m}'
    if [ "$NOW" -lt "$((env_since + GRACE_DAYS * 86400))" ]; then warn "$1" "$2 (an error from $env_fails)"; else fail "$1" "$2"; fi
  }
  while IFS= read -r f; do
    env_bad "$f" "a tracked local environment file: only .env.example (and .env.test, fake values) are committed; staging and production values live in the cluster (ConfigMap, Secret). Remove it from git (git rm --cached) and rotate whatever real value it held"
  done < <(tracked | grep -E '(^|/)\.env($|\.)' | grep -vE '(^|/)\.env\.(example|test)$' | sort)
  # The root .gitignore alone, asked of git in a throwaway repository: no global excludes, no sparse-checkout surprises.
  gi=$(mktemp -d)
  git init -q "$gi" 2>/dev/null
  [ -f .gitignore ] && cp .gitignore "$gi/.gitignore"
  ignored() { git -C "$gi" -c core.excludesFile=/dev/null check-ignore -q --no-index "$1" 2>/dev/null; }
  if ! ignored .env || ! ignored .env.local; then
    env_bad .gitignore "does not ignore .env and .env.* (add both lines, then !.env.example)"
  fi
  if ignored .env.example; then
    env_bad .gitignore "ignores .env.example, the committed template (an old .env* line: replace it with .env, .env.* and !.env.example)"
  fi
  rm -rf "$gi"
  if [ -f Dockerfile ]; then
    # A pattern excludes a name when, without a leading / or **/, it is the name itself or .env* (any line order).
    di=$( [ -f .dockerignore ] && sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s#^/##; s#^\*\*/##' .dockerignore)
    if ! grep -qxE '\.env\*?' <<<"$di" || ! grep -qxE '\.env(\.)?\*' <<<"$di"; then
      env_bad .dockerignore "does not exclude .env and .env.* from the image build (Dockerfile): a local file must never reach an image"
    fi
  fi
  if [ "$role" != library ] && [ -f Dockerfile ] && { [ "$stack" = node ] || [ "$stack" = python ]; }; then
    if ! grep -qx '\.env\.example' < <(tracked); then
      env_bad .env.example "missing: a backend commits .env.example, every variable it reads, commented out but harmless local defaults (an empty variable overrides a default)"
    fi
  fi
  if [ "$stack" = node ] && [ "$role" != library ] && { grep -qE "url *= *.*[/:]${KSKILL_LIB_REPO:-none/none}(\.git)?$" .gitmodules 2>/dev/null \
      || jq -e '((.dependencies // {}) + (.devDependencies // {})) | has($p)' --arg p "$(cfg .workflows.library.package)" package.json >/dev/null 2>&1; }; then
    for sc in start hotstart start-cli hotstart-cli; do
      cmd=$(jq -r --arg s "$sc" '(.scripts // {})[$s] // empty' package.json 2>/dev/null)
      if grep -qE '(^|[;&|[:space:]])node[[:space:]]' <<<"$cmd" && ! grep -qF -- '--env-file-if-exists=.env' <<<"$cmd"; then
        env_bad package.json "script \"$sc\" starts node without --env-file-if-exists=.env (a local run reads the gitignored .env)"
      fi
    done
  fi
fi

# 8. in a repository that uses git-crypt, every secret file is encrypted. A .gitattributes rule that misses a name
# (`*secret.yaml` and a `-secret.yml`) or a directory with none leaves the file in plaintext, and nothing says so.
# Everything is read from the index (in CI, HEAD's tree): a sparse or blob-less clone works, and no key is needed, since
# git stores the encrypted bytes. .
if [ -z "$(cfg .workflows.ci.skip.gitCrypt)" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  gc_uses=false
  if [ -d .git-crypt ] || git ls-files | grep -q '^\.git-crypt/'; then gc_uses=true
  else
    while IFS= read -r f; do
      if git cat-file blob ":$f" 2>/dev/null | grep -q 'filter=git-crypt'; then gc_uses=true; break; fi
    done < <(git ls-files | grep -E '(^|/)\.gitattributes$')
  fi
  if [ "$gc_uses" = true ]; then
    gc_fails=$(jq -n --arg d "$GITCRYPT_FAILS" '$d + "T00:00:00Z" | fromdateiso8601')
    EMPTY_BLOB=$(git hash-object -t blob /dev/null)
    # A YAML file holding a `kind: Secret` document, whatever its name: only a plaintext blob can match (an encrypted
    # one is binary), and that is the one to report. --cached searches every index entry, a sparse checkout's too.
    gc_kind_secret() {
      git grep --cached -I -l -E '^kind:[[:space:]]*Secret[[:space:]]*$' -- ':(icase)*.yaml' ':(icase)*.yml' 2>/dev/null
      return 0
    }
    # A Secret manifest that holds no value (stdin, its plaintext blob): every top-level data:/stringData: entry is the
    # placeholder gitleaks' redaction leaves (GITLEAKS_SECRET_REPLACED) or empty. Backups and archives are kept that way
    # instead of under git-crypt; anything else in those mappings counts as a value. Exit 0: no value.
    gc_no_value() {
      LC_ALL=C awk '
        { sub(/\r$/, "") }
        /^---/ { in_data = 0; next }
        /^([[:space:]]|-)[-[:space:]]*kind:[[:space:]]*Secret[[:space:]]*$/ { bad = 1; exit }
        /^kind:[[:space:]]*Secret[[:space:]]*$/ { secret = 1 }
        in_data && /^[[:space:]]*(#.*)?$/ { next }
        in_data && /^[[:space:]]/ {
          if ($0 !~ /^[[:space:]]+[^[:space:]#][^:]*:[[:space:]]*(GITLEAKS_SECRET_REPLACED|"GITLEAKS_SECRET_REPLACED"|\047GITLEAKS_SECRET_REPLACED\047|""|\047\047|~|null)?[[:space:]]*(#.*)?$/) { bad = 1; exit }
          next
        }
        { in_data = 0 }
        /^(data|stringData):[[:space:]]*(#.*)?$/ { in_data = 1; next }
        /^(data|stringData):[[:space:]]*(\{[[:space:]]*\}|~|null)?[[:space:]]*(#.*)?$/ { next }
        /^(data|stringData):/ { bad = 1; exit }
        END { exit !(secret && !bad) }'
    }
    while IFS= read -r f; do
      why=()
      # (a) the filter attribute, from the index's .gitattributes only (no working-tree edit, no global attributes file).
      attr=$(git -c core.attributesFile=/dev/null check-attr --cached filter -- "$f" 2>/dev/null | sed 's/.*: filter: //')
      [ "$attr" = git-crypt ] || why+=("(a) no .gitattributes rule gives it filter=git-crypt (git check-attr filter: $attr)")
      # (b) the stored bytes: git-crypt's 10-byte header. An empty blob (git add -N) holds nothing to leak.
      blob=$(git ls-files -s -- "$f" | awk 'NR == 1 { print $2 }')
      if [ -n "$blob" ] && [ "$blob" != "$EMPTY_BLOB" ]; then
        hdr=$(git cat-file blob "$blob" 2>/dev/null | head -c 10 | od -An -tx1 | tr -d ' \n')
        [ "$hdr" = 00474954435259505400 ] || why+=("(b) committed in plaintext (no \\0GITCRYPT\\0 header): its values are in the history, rotate them")
      fi
      [ ${#why[@]} = 0 ] && continue
      # A Secret manifest whose values are all replaced holds nothing to encrypt (backups, archives).
      if [ -n "$blob" ] && printf '%s' "$f" | grep -qiE '\.ya?ml$' && git cat-file blob "$blob" 2>/dev/null | gc_no_value; then continue; fi
      msg="a secret file git-crypt does not cover: $(printf '%s; ' "${why[@]}" | sed 's/; $//')"
      rec --arg p "$f" --arg m "$msg" '{kind: "gitcrypt", path: $p, message: $m}'
      if [ "$NOW" -lt "$gc_fails" ]; then warn "$f" "$msg (an error from $GITCRYPT_FAILS)"; else fail "$f" "$msg"; fi
    done < <({ git ls-files | grep -iE '(^|/)secrets/|(^|/)[^/]*secret[^/]*\.ya?ml$|\.secret$'; gc_kind_secret; } | grep -vE '(^|/)\.gitattributes$' | sort -u)
  fi
fi

# 9. a MongoDB connection string never lives in a repository: it comes from the environment only
#. A URI with credentials (user[:password]@) or a host other than the local
# machine (localhost, *.localhost, 127.*, ::1, host.docker.internal) is a finding; a local one without credentials is
# local development, and a test's mongodb-memory-server URI is made at run time, never committed. Placeholders are not
# addresses (`<host>`, `${HOST}`), nor the reserved example names (example.com/.net/.org, *.example, *.invalid,
# *.test). Files: under a `config/` directory, `.env*`, docker-compose/compose files, *.json, *.yaml, *.yml, *.toml,
# *.ini, *.cfg, *.conf, *.properties, and code named *config* or *settings* (.py, .js, .ts, .mjs, .cjs, .mts, .cts),
# lock files excluded. Read from the index when in git (what is committed; a git-crypt file is binary there and
# skipped), only for files on disk (a sparse clone holds just these). Never prints the URI. K5.
mongo_skip=$(jq -r '.workflows.ci.skip.mongoUri // empty | if type == "string" then (if test("^\\s*$") then "" else . end) else "invalid" end' "$CFG" 2>/dev/null)
if [ "$(jq -r '.workflows.ci.skip | if type == "object" then has("mongoUri") else false end' "$CFG" 2>/dev/null)" = true ] \
    && { [ -z "$mongo_skip" ] || [ "$mongo_skip" = invalid ]; }; then
  fail .kheona.json "workflows.ci.skip.mongoUri is the reason check 9 is off: a non-empty string"; mongo_skip=""
fi
if [ -z "$mongo_skip" ]; then
  mongo_fails=$(jq -n --arg d "$MONGO_FAILS" '$d + "T00:00:00Z" | fromdateiso8601')
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then mongo_read() { git cat-file blob ":$1" 2>/dev/null; }
  else mongo_read() { cat "$1" 2>/dev/null; }; fi
  # mongo_why <uri>: what makes it a committed connection string ("credentials", "a non-local host", both), or nothing.
  mongo_why() {
    local rest=${1#*://} auth="" hosts h creds=false remote=false reserved=true; local -a hs
    rest=${rest%%\?*}
    if [[ $rest == *@* ]]; then auth=${rest%@*}; rest=${rest##*@}; fi
    hosts=${rest%%/*}
    IFS=, read -r -a hs <<<"$hosts"
    for h in ${hs[@]+"${hs[@]}"}; do
      h=$(tr '[:upper:]' '[:lower:]' <<<"$h")
      if [[ $h == \[* ]]; then h=${h#[}; h=${h%%]*}; else h=${h%%:*}; fi
      case $h in
        ''|*'<'*|*'>'*|*'$'*|*'{'*|*'}'*) reserved=false ;;  # a placeholder: no address, yet not a fake one either
        example.com|*.example.com|example.net|*.example.net|example.org|*.example.org|*.example|*.invalid|*.test) ;;
        localhost|*.localhost|127.*|::1|host.docker.internal) reserved=false ;;
        *) reserved=false; remote=true ;;
      esac
    done
    [ ${#hs[@]} = 0 ] && reserved=false
    if [ -n "$auth" ] && [[ ! $auth =~ [\<\>\$\{\}] ]] && [ "$reserved" = false ]; then creds=true; fi
    if [ "$creds" = true ] && [ "$remote" = true ]; then echo "credentials and a non-local host"
    elif [ "$creds" = true ]; then echo credentials
    elif [ "$remote" = true ]; then echo "a non-local host"; fi
  }
  MONGO_RE='mongodb(\+srv)?://[^[:space:]"'"'"'`]*'
  mongo_uris() { grep -oE "$MONGO_RE" | sed -E 's/[],;)}]+$//'; }
  mongo_bad() { # mongo_bad <file> <key> <why>
    local msg="holds a MongoDB connection string with $3 at $2: it comes from the environment only (a variable from the cluster's Secret, in the infra repository; a library service declares db.connectionString \"\"). Remove it from git; rotate the password if it held one"
    rec --arg p "$1" --arg k "$2" --arg m "$msg" '{kind: "mongo", path: $p, key: $k, message: $m}'
    if [ "$NOW" -lt "$mongo_fails" ]; then warn "$1" "$msg (an error from $MONGO_FAILS)"; else fail "$1" "$msg"; fi
  }
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    body=$(mongo_read "$f" | LC_ALL=C tr -d '\000-\010\016-\037' 2>/dev/null)
    mongo_read "$f" | grep -qI . || continue  # binary (a git-crypt blob): nothing readable
    grep -qE 'mongodb(\+srv)?://' <<<"$body" || continue
    # JSON: the key is the value's path (a.b.0.c); anything else, the line's key (KEY=, key:, key =) and its number.
    if [[ $f == *.json ]] && keys=$(jq -r 'paths(strings) as $p | getpath($p) | select(test("mongodb(\\+srv)?://")) | [($p | map(tostring) | join(".")), .] | @tsv' <<<"$body" 2>/dev/null); then
      while IFS=$'\t' read -r k v; do
        [ -n "$k" ] || continue
        mwhy=""
        while IFS= read -r u; do w=$(mongo_why "$u"); [ -n "$w" ] && { mwhy=$w; break; }; done < <(printf '%b' "$v" | mongo_uris)
        [ -n "$mwhy" ] && mongo_bad "$f" "$k" "$mwhy"
      done <<<"$keys"
      continue
    fi
    while IFS= read -r line; do
      n=${line%%:*}; line=${line#*:}
      mwhy=""
      while IFS= read -r u; do w=$(mongo_why "$u"); [ -n "$w" ] && { mwhy=$w; break; }; done < <(mongo_uris <<<"$line")
      [ -n "$mwhy" ] || continue
      k=$(sed -nE 's/^[[:space:]]*(#[[:space:]]*)?(export[[:space:]]+)?-?[[:space:]]*["'"'"']?([A-Za-z_][A-Za-z0-9_.-]*)["'"'"']?[[:space:]]*[:=].*/\3/p' <<<"$line")
      mongo_bad "$f" "${k:+$k }(line $n)" "$mwhy"
    done < <(grep -nE 'mongodb(\+srv)?://' <<<"$body")
  done < <(tracked | grep -iE '(^|/)config/|(^|/)\.env($|\.)|(^|/)(docker-)?compose[^/]*\.ya?ml$|\.(json|ya?ml|toml|ini|cfg|conf|properties)$|(^|/)[^/]*(config|settings)[^/]*\.([cm]?[jt]s|py)$' \
    | grep -vE '(^|/)(package-lock\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|yarn\.lock|pubspec\.lock|Pipfile\.lock|poetry\.lock|composer\.lock)$' | sort)
fi

if [ "$JSON" = true ]; then
  jq -s --argjson ok "$([ "$FAIL" = 0 ] && echo true || echo false)" '
    def of($k): map(select(.kind == $k) | del(.kind));
    { ok: $ok, kheonaJson: (map(select(.kind == "kheona"))[0].state // "absent"),
      callers: of("callers"), undeclared: (of("undeclared") | map(.path)), pat: (of("pat") | map(.path)),
      dsn: (of("dsn") | map(.path)), config: (of("config") | map(.path)), env: of("env"), gitCrypt: of("gitcrypt"), mongo: of("mongo"), jobs: (of("job") | map(.job)),
      errors: of("error"), warnings: of("warning") }' "$EVENTS"
elif [ "$FAIL" = 0 ]; then
  echo "kheona-skill repository check: OK"
fi
exit "$FAIL"
