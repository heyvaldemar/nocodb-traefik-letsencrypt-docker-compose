#!/bin/bash
# The backups and both restore scripts, against the live stack, judged
# through NocoDB itself.
#
#   the contract  docker compose config refuses to run with no .env
#   a backup      a dump and an archive appear, each read back whole: the
#                 dump opens and holds NocoDB's tables, the archive lists
#   a failure     PostgreSQL stopped: the next dump is logged FAILED and kept
#                 as .failed, never renamed into place
#   the database  a record made before a backup and one made after it; the
#                 shipped script restores the backup; NocoDB, asked through
#                 Traefik, has the first and not the second, signs the admin
#                 from .env in, and takes a new record
#   attachments   one uploaded before a backup and one after; the shipped
#                 script restores the archive; the first is there with its
#                 owner, the second is gone, and a new upload works
#   pruning       a file dated 2020 is pruned, recent ones are kept
#
# Requires the stack up and healthy, with short intervals in .env (CI uses
# NOCODB_BACKUP_INIT_SLEEP=15s and NOCODB_BACKUP_INTERVAL=60s). Passwords and
# tokens travel to curl in files, never on a command line, and none is
# printed. It stops PostgreSQL and replaces the database and the attachments:
# run it on a staging copy, never on production.
#
# Tests are dispatched by name through run_test; shellcheck cannot trace that
# and flags every one as unused (SC2329).
# shellcheck disable=SC2329
set -euo pipefail
cd "$(dirname "$0")/.."

F=nocodb-traefik-letsencrypt-docker-compose.yml
P=${COMPOSE_PROJECT_NAME:-nocodb}
[ -f .env ] || { echo "error: no .env beside the compose file" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
. ./.env
set +a
HOST=$NOCODB_HOSTNAME
: "${NOCODB_POSTGRES_BACKUPS_PATH:=/srv/nocodb-postgres/backups}"
: "${NOCODB_POSTGRES_BACKUP_NAME:=nocodb-postgres-backup}"
: "${NOCODB_DATA_BACKUPS_PATH:=/srv/nocodb-application-data/backups}"
: "${NOCODB_DATA_BACKUP_NAME:=nocodb-application-data-backup}"
: "${NOCODB_BACKUP_INTERVAL:=24h}"
DB_DIR="${NOCODB_POSTGRES_BACKUPS_PATH%/}"; DB_NAME_PREFIX="$NOCODB_POSTGRES_BACKUP_NAME"
DATA_DIR="${NOCODB_DATA_BACKUPS_PATH%/}"; DATA_NAME_PREFIX="$NOCODB_DATA_BACKUP_NAME"

T="$(mktemp -d)"
chmod 700 "$T"
trap 'rm -rf "$T"' EXIT
compose() { docker compose -f "$F" -p "$P" "$@"; }
cid() { compose ps -aq "$1" | head -1; }
BKP="$(cid backups)"; DB="$(cid postgres)"; APP="$(cid nocodb)"
if [ -z "$BKP" ] || [ -z "$DB" ] || [ -z "$APP" ]; then echo "error: the stack is not up (backups, postgres, nocodb)" >&2; exit 1; fi
bsh() { docker exec "$BKP" sh -c "$1"; }
health() { docker inspect -f '{{.State.Health.Status}}' "$APP" 2>/dev/null; }
wait_healthy() { for _ in $(seq 1 "${1:-180}"); do [ "$(health)" = healthy ] && return 0; sleep 1; done; return 1; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }
api() {  # method path [body-file]: prints the body; the status code is in $T/code
  local m=$1 p=$2 d=${3:-} data=()
  [ -n "$d" ] && data=(--data @"$d")
  curl -sk --resolve "$HOST:443:127.0.0.1" -X "$m" -H @"$T/auth" -H 'Content-Type: application/json' \
    ${data[@]+"${data[@]}"} -o "$T/body" -w '%{http_code}' "https://$HOST$p" >"$T/code"
  cat "$T/body"
}
signin() {
  python3 -c 'import json,os; print(json.dumps({"email":os.environ["NOCODB_ADMIN_EMAIL"],"password":os.environ["NOCODB_ADMIN_PASSWORD"]}))' >"$T/signin.json"
  : >"$T/auth"
  local tok
  tok="$(api POST /api/v1/auth/user/signin "$T/signin.json" | json 'd.get("token","")')"
  [ -n "$tok" ] || return 1
  printf 'xc-auth: %s\n' "$tok" >"$T/auth"
}
record() {  # name: add a record to the e2e table
  N="$1" python3 -c 'import json,os; print(json.dumps([{"Name":os.environ["N"]}]))' >"$T/rec.json"
  api POST "/api/v2/tables/$TID/records" "$T/rec.json" >/dev/null
  [ "$(cat "$T/code")" = 200 ]
}
names() { api GET "/api/v2/tables/$TID/records?limit=100" | json '" ".join(sorted(r["Name"] for r in d["list"]))'; }
upload() {  # name: upload a small file, print its path on disk under /usr/app/data/nc/uploads
  printf '%s\n' "$1" >"$T/$1.txt"
  curl -sk --resolve "$HOST:443:127.0.0.1" -H @"$T/auth" -F "file=@$T/$1.txt" "https://$HOST/api/v2/storage/upload?path=e2e" \
    | json '"/usr/app/data/nc/uploads/" + d[0]["path"].split("download/",1)[1]'
}

interval_seconds() {
  local v="$NOCODB_BACKUP_INTERVAL"
  case "$v" in *h) echo $(( ${v%h} * 3600 )) ;; *m) echo $(( ${v%m} * 60 )) ;; *s) echo "${v%s}" ;; *) echo "$v" ;; esac
}
CYCLE_WAIT=$(( $(interval_seconds) + 120 ))
# The first dump and archive written after the stamp, each named in its OK
# line: a file that exists may still be being written.
after_stamp() {  # dir prefix ext label
  local f waited=0
  while :; do
    f="$(bsh "find $1 -name '$2-*$3' -newer $1/.e2e-stamp 2>/dev/null | sort | head -1")"
    if [ -n "$f" ] && docker logs "$BKP" 2>&1 | grep -qF "$4 backup OK: $f"; then echo "$f"; return 0; fi
    [ "$waited" -lt "$CYCLE_WAIT" ] || return 1
    sleep 5; waited=$((waited + 5))
  done
}

PASSED=0; FAILED=0; FAILURES=()
run_test() {
  echo; echo "=== $1 ==="
  if "$1"; then echo "  PASS: $1"; PASSED=$((PASSED + 1)); else echo "  FAIL: $1" >&2; FAILED=$((FAILED + 1)); FAILURES+=("$1"); fi
}
fail() { echo "  ASSERT: $*" >&2; return 1; }

test_env_required() {
  /bin/mv -f .env .env.e2e-held
  local out
  out="$(env -i PATH="$PATH" HOME="$HOME" docker compose -f "$F" config 2>&1 || true)"
  /bin/mv -f .env.e2e-held .env
  grep -qiE "set in \.env|required|is not set" <<<"$out" || { fail "docker compose config ran without .env"; return 1; }
  echo "  refused: $(grep -m1 -oiE '[A-Z_]+: set in \.env[^"]*' <<<"$out" || head -1 <<<"$out")"
}

test_backup_valid() {
  local db data
  db="$(after_stamp "$DB_DIR" "$DB_NAME_PREFIX" .gz Database)" || { fail "no database backup after the stamp within ${CYCLE_WAIT}s"; return 1; }
  bsh "gunzip -t '$db'" || { fail "gunzip -t failed on $db"; return 1; }
  bsh "gunzip -c '$db' | head -5" | grep -q "PostgreSQL database dump" || { fail "$db does not start as a PostgreSQL dump"; return 1; }
  local tables
  tables="$(bsh "gunzip -c '$db' | grep -cE '^CREATE TABLE public\\.nc_'" || true)"
  [ "${tables:-0}" -gt 10 ] || { fail "$db holds $tables of NocoDB's nc_ tables"; return 1; }
  echo "  $db: opens, $tables nc_ tables"
  data="$(after_stamp "$DATA_DIR" "$DATA_NAME_PREFIX" .tar.gz Data)" || { fail "no data archive after the stamp within ${CYCLE_WAIT}s"; return 1; }
  bsh "tar -tzf '$data'" | grep -qF "${BEFORE_FILE#/}" || { fail "$data lists no $BEFORE_FILE"; return 1; }
  echo "  $data: lists, and holds the attachment uploaded before it"
}

test_backup_failure_detected() {
  local before deadline
  before="$(docker logs "$BKP" 2>&1 | grep -c "Database backup FAILED" || true)"
  echo "  stopping PostgreSQL to make the next dump fail"
  docker stop "$DB" >/dev/null
  deadline=$(( $(date +%s) + CYCLE_WAIT * 2 ))
  while [ "$(docker logs "$BKP" 2>&1 | grep -c "Database backup FAILED" || true)" -le "$before" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 5
  done
  local failed
  failed="$(bsh "ls $DB_DIR/*.failed 2>/dev/null" || true)"
  docker start "$DB" >/dev/null
  wait_healthy 180 || { fail "NocoDB did not come back after PostgreSQL did"; return 1; }
  [ "$(docker logs "$BKP" 2>&1 | grep -c "Database backup FAILED" || true)" -gt "$before" ] || { fail "no FAILED line during the outage"; return 1; }
  [ -n "$failed" ] || { fail "no .failed file during the outage"; return 1; }
  echo "  logged FAILED, kept as: $failed"
}

test_database_restore() {
  local baseline
  baseline="$(after_stamp "$DB_DIR" "$DB_NAME_PREFIX" .gz Database)" || { fail "no database backup after the stamp"; return 1; }
  signin || { fail "the admin did not sign in"; return 1; }
  record "made-after-the-backup" || { fail "could not add the after-backup record"; return 1; }
  [ "$(names)" = "made-after-the-backup made-before-the-backup" ] || { fail "before the restore the table holds: $(names)"; return 1; }
  echo "  restoring $(basename "$baseline") with ./nocodb-restore-database.sh"
  COMPOSE_PROJECT_NAME="$P" ./nocodb-restore-database.sh "$(basename "$baseline")" || { fail "the shipped restore script failed"; return 1; }
  wait_healthy 180 || { fail "NocoDB did not come back healthy after the restore"; return 1; }
  signin || { fail "the admin from .env did not sign in to the restored database"; return 1; }
  local got
  got="$(names)"
  [ "$got" = "made-before-the-backup" ] || { fail "after the restore the table holds: '$got'"; return 1; }
  echo "  after the restore: '$got', and the after-backup record is gone"
  record "written-after-the-restore" || { fail "the restored database refused a new record"; return 1; }
  echo "  and it takes a new record"
}

test_data_restore() {
  local archive after
  archive="$(after_stamp "$DATA_DIR" "$DATA_NAME_PREFIX" .tar.gz Data)" || { fail "no data archive after the stamp"; return 1; }
  signin || { fail "the admin did not sign in"; return 1; }
  after="$(upload made-after-the-backup)"
  if [ -z "$after" ] || ! docker exec "$APP" test -f "$after"; then fail "the after-backup upload is not on disk"; return 1; fi
  echo "  restoring $(basename "$archive") with ./nocodb-restore-application-data.sh"
  COMPOSE_PROJECT_NAME="$P" ./nocodb-restore-application-data.sh "$(basename "$archive")" || { fail "the shipped restore script failed"; return 1; }
  wait_healthy 180 || { fail "NocoDB did not come back healthy after the restore"; return 1; }
  docker exec "$APP" test -f "$BEFORE_FILE" || { fail "the attachment from before the backup is missing"; return 1; }
  ! docker exec "$APP" test -e "$after" || { fail "the attachment from after the backup survived the restore"; return 1; }
  local owner
  owner="$(docker exec "$APP" stat -c %u:%g "$BEFORE_FILE" /usr/app/data | sort -u | tr '\n' ' ')"
  [ "$owner" = "1000:1000 " ] || { fail "after the restore the files and the directory belong to: $owner"; return 1; }
  echo "  the before-backup attachment is back, owned by 1000:1000 with its directory; the after-backup one is gone"
  signin || { fail "the admin did not sign in"; return 1; }
  local new
  new="$(upload written-after-the-restore)"
  if [ -z "$new" ] || ! docker exec "$APP" test -f "$new"; then fail "NocoDB could not write an attachment after the restore"; return 1; fi
  echo "  and NocoDB writes a new attachment"
}

test_prune() {
  local fake="$DB_DIR/$DB_NAME_PREFIX-0000-00-00_00-00.gz" ceiling waited=0
  bsh "echo fake > '$fake' && touch -t 202001010000 '$fake'" || { fail "could not place the fake old file"; return 1; }
  ceiling=$(( $(interval_seconds) * 2 + 300 ))
  while bsh "test -e '$fake'"; do
    [ "$waited" -lt "$ceiling" ] || { fail "a file dated 2020 survived ${ceiling}s"; return 1; }
    sleep 5; waited=$((waited + 5))
  done
  [ -n "$(bsh "ls $DB_DIR/$DB_NAME_PREFIX-*.gz 2>/dev/null")" ] || { fail "the prune removed the recent backups too"; return 1; }
  echo "  pruned after ${waited}s; recent backups kept"
}

echo "=== backup and restore, end to end ==="
echo "  project=$P backups=$BKP postgres=$DB nocodb=$APP interval=$NOCODB_BACKUP_INTERVAL"
wait_healthy 180 || { echo "error: NocoDB is not healthy" >&2; exit 1; }
signin || { echo "error: the admin from .env does not sign in" >&2; exit 1; }
# Known state before the stamp: a base with one record, and one attachment.
python3 -c 'import json; print(json.dumps({"title":"e2e-backup"}))' >"$T/base.json"
BID="$(api POST /api/v2/meta/bases "$T/base.json" | json 'd["id"]')"
python3 -c 'import json; print(json.dumps({"table_name":"e2e_records","title":"Records","columns":[{"column_name":"name","title":"Name","uidt":"SingleLineText"}]}))' >"$T/table.json"
TID="$(api POST "/api/v2/meta/bases/$BID/tables" "$T/table.json" | json 'd["id"]')"
[ -n "$BID" ] && [ -n "$TID" ] || { echo "error: could not make the e2e base and table" >&2; exit 1; }
record "made-before-the-backup" || { echo "error: could not add the first record" >&2; exit 1; }
BEFORE_FILE="$(upload made-before-the-backup)"
[ -n "$BEFORE_FILE" ] || { echo "error: could not upload the first attachment" >&2; exit 1; }
bsh "touch '$DB_DIR/.e2e-stamp' '$DATA_DIR/.e2e-stamp'"

run_test test_env_required
run_test test_backup_valid
run_test test_backup_failure_detected
run_test test_database_restore
run_test test_data_restore
run_test test_prune

echo
echo "==============================="
echo "Passed: $PASSED  Failed: $FAILED"
if [ ${#FAILURES[@]} -gt 0 ]; then printf 'Failures:\n'; printf '  - %s\n' "${FAILURES[@]}"; fi
[ "$FAILED" -eq 0 ]
