#!/usr/bin/env bash
# nocodb-restore-database.sh [backup-file-name]
#
# Replaces NocoDB's database with one of the dumps the backups service wrote.
# The database is everything but the attachments: every base, table, row,
# view, user and setting, and the connections to the databases NocoDB fronts.
#
#   ./nocodb-restore-database.sh               list and ask
#   ./nocodb-restore-database.sh <file-name>   restore that one
#
# THE SAME NOCODB_CONNECTION_ENCRYPT_KEY. A dump holds the connections to
# other databases encrypted with that key; restored under another one, NocoDB
# starts and cannot open them. The super admin's email and password are set
# again from .env when NocoDB starts, so the restored database signs in with
# the ones in .env, not the ones it had.
#
# EVERY PATH, NAME AND CREDENTIAL COMES FROM THE RUNNING BACKUPS CONTAINER.
# The backup loop reads its own environment, so this reads the same one, and
# the two cannot disagree. Containers are found by their compose labels, so
# any -p works with COMPOSE_PROJECT_NAME set.
#
# CI runs this exact file: a record made after the backup is gone afterwards,
# a record made before it is back, and a new record can be written.
#
# Set COMPOSE_PROJECT_NAME if the stack was started with a -p other than nocodb.
set -Eeuo pipefail

PROJECT="${COMPOSE_PROJECT_NAME:-nocodb}"
APP_SERVICE="nocodb"

cid() {  # the container of one compose service in this project
  docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$1" | head -n 1
}
APP="$(cid "$APP_SERVICE")"; BKP="$(cid backups)"
[ -n "$BKP" ] || { echo "error: no backups container in compose project '$PROJECT' (set COMPOSE_PROJECT_NAME)" >&2; exit 1; }
[ -n "$APP" ] || { echo "error: no $APP_SERVICE container in compose project '$PROJECT'" >&2; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' "$BKP")" = true ] || { echo "error: the backups container is not running" >&2; exit 1; }

env_of() { docker exec "$BKP" printenv "$1"; }
DIR="$(env_of NOCODB_POSTGRES_BACKUPS_PATH)"; NAME="$(env_of NOCODB_POSTGRES_BACKUP_NAME)"
DB_NAME="$(env_of NOCODB_DB_NAME)"; DB_USER="$(env_of NOCODB_DB_USER)"

SELECTED="${1:-}"
if [ -z "$SELECTED" ]; then
  echo "Database backups in $DIR:"
  docker exec "$BKP" sh -c "ls -1 '$DIR' | grep -E '^$NAME-.*\\.gz\$'" || { echo "  none found" >&2; exit 1; }
  read -r -p "File name to restore: " SELECTED
fi
case "$SELECTED" in ""|*/*) echo "error: give a file name from the list, not a path" >&2; exit 1 ;; esac
docker exec "$BKP" gunzip -t "$DIR/$SELECTED" >/dev/null \
  || { echo "error: $DIR/$SELECTED is missing or does not open; nothing was changed" >&2; exit 1; }

echo "Stopping $APP_SERVICE so nothing writes while the database is replaced"
docker stop "$APP" >/dev/null
restart() { docker start "$APP" >/dev/null && echo "Started $APP_SERVICE"; }
trap 'restart' EXIT
echo "Restoring $SELECTED"
if ! docker exec "$BKP" bash -c "set -euo pipefail
    dropdb --force -h postgres -U '$DB_USER' --if-exists '$DB_NAME'
    createdb -h postgres -U '$DB_USER' '$DB_NAME'
    gunzip -c '$DIR/$SELECTED' | psql -q -v ON_ERROR_STOP=1 -h postgres -U '$DB_USER' -d '$DB_NAME' >/dev/null"; then
  echo "error: the restore failed part-way. The database may now be empty: restore another backup before using NocoDB." >&2
  exit 1
fi
echo "Restored $SELECTED into $DB_NAME"
