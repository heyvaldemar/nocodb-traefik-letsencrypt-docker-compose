#!/bin/bash
# What the compose file claims about access and secrets, against the live
# stack, through Traefik. The claims that say "without this, that" run both
# ways, with a test-only override from tests/overrides/ for the "without".
#
#   the process      NocoDB as uid 1000 with no capabilities
#   the admin        the super admin from .env signs in; nobody else is first
#                    user; a stranger who signs up is a viewer who cannot make
#                    a base, and is refused outright once signup is
#                    invite-only
#   the health check /api/v1/health says 200 with PostgreSQL stopped; the
#                    shipped check says 400 and Docker marks NocoDB unhealthy
#   private networks a data source on the stack's own PostgreSQL is refused
#   attachments      the plain URL 404, the signed one 200, a forged one 404;
#                    with NC_SECURE_ATTACHMENTS off, the plain URL is served
#   secrets          the signing secret is not in the database; a connected
#                    database's password is in a backup without the
#                    encryption key and gone from one with it, the connection
#                    still reads, and with another key it does not
#   the audit log    a change is logged from the client's address, not a
#                    forged X-Forwarded-For; without NC_TRUST_PROXY, from
#                    Traefik's
#
# Requires the stack up and healthy, with the .env the compose file reads.
# Passwords and tokens travel to curl in files (mode 600, in a directory this
# script removes), never on a command line, and none is printed. It stops
# PostgreSQL and recreates NocoDB several times: run it on a staging copy,
# never on production.
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

F=nocodb-traefik-letsencrypt-docker-compose.yml
P=${COMPOSE_PROJECT_NAME:-nocodb}
[ -f .env ] || { echo "error: no .env beside the compose file" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
. ./.env
set +a
HOST=$NOCODB_HOSTNAME
DB_NAME=${NOCODB_DB_NAME:-nocodbdb}
DB_USER=${NOCODB_DB_USER:-nocodbdbuser}

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

T="$(mktemp -d)"
chmod 700 "$T"
trap 'rm -rf "$T"' EXIT
compose() { docker compose -f "$F" -p "$P" "$@"; }
cid() { compose ps -aq "$1" | head -1; }
health() { docker inspect -f '{{.State.Health.Status}}' "$(cid nocodb)" 2>/dev/null; }
wait_health() {  # status seconds
  for _ in $(seq 1 "$2"); do [ "$(health)" = "$1" ] && return 0; sleep 1; done
  return 1
}
# `docker compose up` with an extra file layered on, then wait for NocoDB.
recreate() {
  local extra=()
  [ -n "${1:-}" ] && extra=(-f "tests/overrides/$1")
  docker compose -f "$F" ${extra[@]+"${extra[@]}"} -p "$P" up -d nocodb >/dev/null 2>&1 || return 1
  wait_health healthy 180
}
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }
# A request through Traefik. The auth header comes from a file; a body, when
# given, is a file too. Prints the body; the status code is in $T/code.
api() {  # method path [body-file] [extra curl args...]
  local m=$1 p=$2 d=${3:-} data=()
  if [ $# -ge 3 ]; then shift 3; else shift $#; fi
  [ -n "$d" ] && data=(--data @"$d")
  curl -sk --resolve "$HOST:443:127.0.0.1" -X "$m" -H @"$T/auth" -H 'Content-Type: application/json' \
    ${data[@]+"${data[@]}"} "$@" -o "$T/body" -w '%{http_code}' "https://$HOST$p" >"$T/code"
  cat "$T/body"
}
code() { cat "$T/code"; }
body() {  # name, then a python expression over os.environ: writes a JSON body file
  python3 -c "import json,os; print(json.dumps($2))" >"$T/$1.json"
}
signin() {  # email-var password-var: the auth file holds that user's token
  E="${!1}" W="${!2}" python3 -c 'import json,os; print(json.dumps({"email":os.environ["E"],"password":os.environ["W"]}))' >"$T/signin.json"
  : >"$T/auth"
  local tok
  tok="$(api POST /api/v1/auth/user/signin "$T/signin.json" | json 'd.get("token","")')"
  [ -n "$tok" ] || return 1
  printf 'xc-auth: %s\n' "$tok" >"$T/auth"
}
# SQL goes in on stdin, over the container's own socket, so no password and
# no statement holding one is ever on a command line.
psql_q() { printf '%s\n' "$1" | docker exec -i "$(cid postgres)" psql -q -U "$DB_USER" -d "${2:-$DB_NAME}" -tA; }
dump_has() {  # string: how many lines of a fresh pg_dump hold it
  local dump
  dump="$(docker exec "$(cid postgres)" pg_dump -U "$DB_USER" -d "$DB_NAME")"
  grep -cF -- "$1" <<<"$dump"
}

echo "=== the process ==="
echo
# Every process in the container: dumb-init, the start script and node.
procs="$(docker exec "$(cid nocodb)" sh -c 'for p in /proc/[0-9]*; do [ -r "$p/status" ] && [ "${p#/proc/}" != "$$" ] || continue; printf "%s uid=%s cap=%s\n" "$(cat "$p/comm")" "$(sed -n "s/^Uid:\t\([0-9]*\).*/\1/p" "$p/status")" "$(sed -n "s/^CapEff:\t//p" "$p/status")"; done')"
n="$(grep -c . <<<"$procs")"
others="$(grep -v 'uid=1000 cap=0000000000000000$' <<<"$procs" || true)"
[ "$n" -ge 3 ] && [ -z "$others" ] && pass "all $n processes in the NocoDB container run as uid 1000 with no capabilities (CapEff 0000000000000000): $(awk '{print $1}' <<<"$procs" | sort -u | tr '\n' ' ')" \
  || fail "processes not uid 1000 with no capabilities: ${others:-none found ($n)}"
owner="$(docker exec "$(cid nocodb)" stat -c %u:%g /usr/app/data)"
[ "$owner" = 1000:1000 ] && pass "/usr/app/data belongs to it ($owner), from nocodb-init" || fail "/usr/app/data is $owner"

echo
echo "=== the admin, and everybody else ==="
echo
: >"$T/auth"
info="$(api GET /api/v2/meta/nocodb/info)"
[ "$(json 'd["firstUser"]' <<<"$info")" = False ] && pass "nobody is first user: the super admin existed before the site answered" || fail "info says firstUser: $(json 'd.get("firstUser")' <<<"$info")"
[ "$(json 'd["teleEnabled"]' <<<"$info")" = False ] && pass "telemetry off" || fail "teleEnabled: $(json 'd.get("teleEnabled")' <<<"$info")"
signin NOCODB_ADMIN_EMAIL NOCODB_ADMIN_PASSWORD && roles="$(api GET /api/v1/auth/user/me | json 'sorted(d["roles"])')"
[ "${roles:-}" = "['org-level-creator', 'super']" ] && pass "the admin from .env signs in as super admin" || fail "the admin from .env: ${roles:-did not sign in}"
cp "$T/auth" "$T/admin"
export STRANGER_EMAIL="stranger-$RANDOM@example.org" STRANGER_PASSWORD
STRANGER_PASSWORD="St-$(openssl rand -hex 8)-7"
body stranger '{"email":os.environ["STRANGER_EMAIL"],"password":os.environ["STRANGER_PASSWORD"]}'
: >"$T/auth"
api POST /api/v1/auth/user/signup "$T/stranger.json" >/dev/null
signin STRANGER_EMAIL STRANGER_PASSWORD && sroles="$(api GET /api/v1/auth/user/me | json 'sorted(d["roles"])')"
[ "${sroles:-}" = "['org-level-viewer']" ] && pass "a stranger who signs up is a viewer" || fail "a stranger's roles: ${sroles:-did not sign in}"
body base '{"title":"strangers-base"}'
api POST /api/v2/meta/bases "$T/base.json" >/dev/null
[ "$(code)" = 403 ] && pass "and cannot make a base: 403" || fail "a stranger making a base: $(code)"
cp "$T/admin" "$T/auth"
body invite '{"invite_only_signup":True}'
api POST /api/v1/app-settings "$T/invite.json" >/dev/null
export STRANGER_EMAIL="stranger-$RANDOM-2@example.org"
body stranger '{"email":os.environ["STRANGER_EMAIL"],"password":os.environ["STRANGER_PASSWORD"]}'
: >"$T/auth"
out="$(api POST /api/v1/auth/user/signup "$T/stranger.json")"
[ "$(code)" = 400 ] && grep -q "Not allowed to signup" <<<"$out" && pass "with signup set to invite-only, the next stranger is refused: $(json 'd.get("msg") or d.get("message")' <<<"$out")" \
  || fail "invite-only signup: $(code) $out"
cp "$T/admin" "$T/auth"
body invite '{"invite_only_signup":False}'
api POST /api/v1/app-settings "$T/invite.json" >/dev/null

echo
echo "=== the health check, with PostgreSQL stopped ==="
echo
docker stop "$(cid postgres)" >/dev/null
sleep 3
status_of() { docker exec "$(cid nocodb)" wget -S -O /dev/null "http://127.0.0.1:8080$1" 2>&1 | sed -n 's/^ *HTTP\/[0-9.]* \([0-9]*\).*/\1/p' | tail -1; }
legacy="$(status_of /api/v1/health)"
shipped="$(status_of /api/v2/meta/nocodb/info)"
[ "$legacy" = 200 ] && pass "/api/v1/health with PostgreSQL stopped: 200, which is why it is not the health check" || fail "/api/v1/health with PostgreSQL stopped: ${legacy:-no answer} (the comment in the compose file would be wrong)"
[ "$shipped" = 400 ] && pass "the shipped check's endpoint with PostgreSQL stopped: 400" || fail "the shipped check's endpoint with PostgreSQL stopped: ${shipped:-no answer}"
wait_health unhealthy 90 && pass "and Docker marks NocoDB unhealthy" || fail "PostgreSQL stopped and NocoDB still $(health)"
docker start "$(cid postgres)" >/dev/null
wait_health healthy 120 && pass "PostgreSQL back: healthy again" || fail "PostgreSQL back and NocoDB still $(health)"

echo
echo "=== private networks ==="
echo
cp "$T/admin" "$T/auth"
body base '{"title":"e2e-sources"}'
BID="$(api POST /api/v2/meta/bases "$T/base.json" | json 'd["id"]')"
export SRC_PASSWORD
SRC_PASSWORD="ext-$(openssl rand -hex 12)"
body source '{"alias":"external","type":"pg","config":{"client":"pg","connection":{"host":"postgres","port":5432,"user":"e2e_external","password":os.environ["SRC_PASSWORD"],"database":"e2e_external"}}}'
body meta '{"alias":"meta","type":"pg","config":{"client":"pg","connection":{"host":"postgres","port":5432,"user":os.environ.get("NOCODB_DB_USER","nocodbdbuser"),"password":os.environ["NOCODB_DB_PASSWORD"],"database":os.environ.get("NOCODB_DB_NAME","nocodbdb")}}}'
out="$(api POST "/api/v2/meta/bases/$BID/sources" "$T/meta.json")"
grep -q "Connection to internal hosts is not allowed" <<<"$out" && pass "a data source on the stack's own PostgreSQL, which holds every account: refused, \"$(json 'd.get("msg")' <<<"$out")\"" \
  || fail "a data source on the stack's own PostgreSQL: $(code) $out"

echo
echo "=== attachments ==="
echo
printf 'e2e attachment %s\n' "$RANDOM" >"$T/file.txt"
up="$(curl -sk --resolve "$HOST:443:127.0.0.1" -H @"$T/auth" -F "file=@$T/file.txt" "https://$HOST/api/v2/storage/upload?path=e2e")"
plain="$(json 'd[0]["path"]' <<<"$up")"; signed="$(json 'd[0]["signedPath"]' <<<"$up")"
get() { curl -sk --resolve "$HOST:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$HOST/$1"; }
[ "$(get "$plain")" = 404 ] && pass "the plain URL, with no session: 404" || fail "the plain URL: $(get "$plain")"
[ "$(get "$signed")" = 200 ] && pass "the signed URL: 200" || fail "the signed URL: $(get "$signed")"
forged="${signed/#dltemp\//dltemp/x}"
[ "$(get "$forged")" = 404 ] && pass "a forged signature: 404" || fail "a forged signature: $(get "$forged")"
recreate plain-attachments.yml || fail "NocoDB did not come back with secure attachments off"
[ "$(get "$plain")" = 200 ] && pass "with NC_SECURE_ATTACHMENTS off, the same plain URL is served to anyone: 200" \
  || fail "with secure attachments off the plain URL is $(get "$plain") (the comment in the compose file would be wrong)"
recreate || fail "NocoDB did not come back on the shipped settings"
[ "$(get "$plain")" = 404 ] && pass "back on the shipped settings: 404 again" || fail "back on the shipped settings: $(get "$plain")"

echo
echo "=== secrets that stay out of the database ==="
echo
[ "$(psql_q "select count(*) from nc_store where key = 'nc_auth_jwt_secret'")" = 0 ] && pass "no signing secret in nc_store: it comes from .env" || fail "nc_store holds nc_auth_jwt_secret"
# A database for NocoDB to front, inside the stack.
psql_q "create user e2e_external with password '$SRC_PASSWORD'" >/dev/null
psql_q "create database e2e_external owner e2e_external" >/dev/null
psql_q "set role e2e_external; create table parts (id serial primary key, name text); insert into parts (name) values ('bolt')" e2e_external >/dev/null
recreate no-encrypt-key.yml || fail "NocoDB did not come back without the key"
signin NOCODB_ADMIN_EMAIL NOCODB_ADMIN_PASSWORD; cp "$T/auth" "$T/admin"
api POST "/api/v2/meta/bases/$BID/sources" "$T/source.json" >/dev/null
for _ in $(seq 1 30); do
  [ "$(api GET "/api/v2/meta/bases/$BID/sources" | json 'len([s for s in d["list"] if s.get("alias")=="external"])')" = 1 ] && break
  sleep 2
done
n="$(dump_has "$SRC_PASSWORD")"
[ "$n" -ge 1 ] && pass "without NC_CONNECTION_ENCRYPT_KEY, a backup of the database carries the connected database's password: $n line(s)" \
  || fail "without the key the password is not in the dump ($n): the comment in the compose file would be wrong"
recreate local-dbs.yml || fail "NocoDB did not come back with the key"
grep -q "Encrypted source external" <<<"$(docker logs "$(cid nocodb)" 2>&1)" && pass "with the key, NocoDB encrypted the stored connection on start" || fail "no \"Encrypted source external\" in the log"
n="$(dump_has "$SRC_PASSWORD")"
[ "$n" = 0 ] && pass "and a backup no longer holds the password" || fail "with the key the password is still in the dump: $n line(s)"
signin NOCODB_ADMIN_EMAIL NOCODB_ADMIN_PASSWORD
TID="$(api GET "/api/v2/meta/bases/$BID/tables" | json '[t["id"] for t in d["list"] if t["title"]=="parts"][0]')"
rows="$(api GET "/api/v2/tables/$TID/records" | json 'd["list"][0]["name"]')"
[ "$rows" = bolt ] && pass "the encrypted connection still reads: parts.name = $rows" || fail "reading through the encrypted connection: $(code) $(cat "$T/body")"
recreate wrong-encrypt-key.yml || fail "NocoDB did not come back with another key"
signin NOCODB_ADMIN_EMAIL NOCODB_ADMIN_PASSWORD
rows="$(api GET "/api/v2/tables/$TID/records" | json 'd["list"][0]["name"]')"
[ "$rows" != bolt ] && pass "under another key it does not ($(code)): restore with the key the backup was made under" || fail "under another key the connection still read"
recreate || fail "NocoDB did not come back on the shipped settings"
signin NOCODB_ADMIN_EMAIL NOCODB_ADMIN_PASSWORD; cp "$T/auth" "$T/admin"
out="$(api GET "/api/v2/tables/$TID/records")"
grep -q "Connection to internal hosts is not allowed" <<<"$out" && pass "and on the shipped settings, a connection made while private networks were allowed is refused when it is used" \
  || fail "the stored private connection on the shipped settings: $(code) $out"
api DELETE "/api/v2/meta/bases/$BID" >/dev/null
psql_q "drop database e2e_external with (force)" >/dev/null; psql_q "drop user e2e_external" >/dev/null

echo
echo "=== the audit log and X-Forwarded-For ==="
echo
# NocoDB audits changes to data with the address it believes they came from.
audited_ip() {  # insert one record, sent with a forged X-Forwarded-For; print the address logged
  signin NOCODB_ADMIN_EMAIL NOCODB_ADMIN_PASSWORD
  body abase '{"title":"e2e-audit"}'
  local b t
  b="$(api POST /api/v2/meta/bases "$T/abase.json" | json 'd["id"]')"
  body atable '{"table_name":"audit","title":"Audit","columns":[{"column_name":"n","title":"N","uidt":"SingleLineText"}]}'
  t="$(api POST "/api/v2/meta/bases/$b/tables" "$T/atable.json" | json 'd["id"]')"
  body arow '[{"N":"audited"}]'
  api POST "/api/v2/tables/$t/records" "$T/arow.json" -H 'X-Forwarded-For: 203.0.113.77' >/dev/null
  sleep 2
  psql_q "select ip from nc_audit_v2 where op_type = 'DATA_INSERT' and fk_model_id = '$t' order by created_at desc limit 1" | tr -d '[:space:]'
  api DELETE "/api/v2/meta/bases/$b" >/dev/null
}
traefik_ips="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$(cid traefik)")"
is_traefik() { local a=${1#::ffff:}; [ -n "$a" ] && grep -qw -- "$a" <<<"$traefik_ips"; }
ip="$(audited_ip)"
if [ -z "$ip" ]; then
  fail "no DATA_INSERT in nc_audit_v2 to read an address from"
elif [ "$ip" = 203.0.113.77 ]; then
  fail "the audit log kept the forged address 203.0.113.77"
elif is_traefik "$ip"; then
  fail "the audit log names Traefik ($ip) as the source: NC_TRUST_PROXY is not reaching NocoDB"
else
  pass "a record added with a forged X-Forwarded-For: 203.0.113.77 is logged from $ip, the address Traefik saw"
fi
recreate no-trust-proxy.yml || fail "NocoDB did not come back without NC_TRUST_PROXY"
ip="$(audited_ip)"
is_traefik "$ip" && pass "with NocoDB's own default (no proxy trusted), the same change is logged from $ip, Traefik's container" \
  || fail "without NC_TRUST_PROXY the log says ${ip:-nothing} (the comment in the compose file would be wrong)"
recreate || fail "NocoDB did not come back on the shipped settings"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
