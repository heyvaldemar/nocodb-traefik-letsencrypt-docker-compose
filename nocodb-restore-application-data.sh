#!/usr/bin/env bash
# nocodb-restore-application-data.sh [backup-file-name]
#
# Replaces NocoDB's attachments and files (/usr/app/data) with one of the
# archives the backups service wrote. The database is restored separately,
# with nocodb-restore-database.sh; restore both from the same cycle.
#
#   ./nocodb-restore-application-data.sh               list and ask
#   ./nocodb-restore-application-data.sh <file-name>   restore that one
#
# UNPACKED FIRST, THEN SWAPPED IN. The archive goes into a staging directory
# inside the volume, and only once it has unpacked whole is what was there
# removed and the restored files moved into place, so a bad archive changes
# nothing. What was there is removed so that files written after the backup
# do not survive the restore. The files keep the owner they were archived with
# (uid 1000, the user NocoDB runs as), and so does the directory itself, so
# NocoDB can write again afterwards; CI uploads an attachment after the
# restore to prove it.
#
# EVERY PATH AND NAME COMES FROM THE RUNNING BACKUPS CONTAINER, which reads
# the same environment as the backup loop. Containers are found by their
# compose labels, so any -p works with COMPOSE_PROJECT_NAME set.
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
DIR="$(env_of NOCODB_DATA_BACKUPS_PATH)"; NAME="$(env_of NOCODB_DATA_BACKUP_NAME)"; DATA="$(env_of NOCODB_DATA_PATH)"
case "$DATA" in ""|/) echo "error: NOCODB_DATA_PATH is '$DATA'; refusing to clear it" >&2; exit 1 ;; esac

SELECTED="${1:-}"
if [ -z "$SELECTED" ]; then
  echo "Application data backups in $DIR:"
  docker exec "$BKP" sh -c "ls -1 '$DIR' | grep -E '^$NAME-.*\\.tar\\.gz\$'" || { echo "  none found" >&2; exit 1; }
  read -r -p "File name to restore: " SELECTED
fi
case "$SELECTED" in ""|*/*) echo "error: give a file name from the list, not a path" >&2; exit 1 ;; esac
docker exec "$BKP" tar -tzf "$DIR/$SELECTED" >/dev/null \
  || { echo "error: $DIR/$SELECTED is missing or does not open; nothing was changed" >&2; exit 1; }

echo "Stopping $APP_SERVICE so nothing writes while its files are replaced"
docker stop "$APP" >/dev/null
restart() { docker start "$APP" >/dev/null && echo "Started $APP_SERVICE"; }
trap 'restart' EXIT
echo "Restoring $SELECTED"
# The loop archives the directory as usr/app/data, relative to /.
STAGE="$DATA/.restore-staging"
if ! docker exec "$BKP" bash -c "set -euo pipefail
    rm -rf '$STAGE'; mkdir '$STAGE'
    tar -xzpf '$DIR/$SELECTED' -C '$STAGE'
    [ -d '$STAGE/usr/app/data' ] || { echo 'the archive holds no usr/app/data' >&2; rm -rf '$STAGE'; exit 1; }
    find '$DATA' -mindepth 1 -maxdepth 1 ! -name .restore-staging -exec rm -rf {} +
    find '$STAGE/usr/app/data' -mindepth 1 -maxdepth 1 -exec mv {} '$DATA'/ \;
    chown \"\$(stat -c %u:%g '$STAGE/usr/app/data')\" '$DATA'
    chmod \"\$(stat -c %a '$STAGE/usr/app/data')\" '$DATA'
    rm -rf '$STAGE'"; then
  echo "error: the restore failed. If it failed while unpacking, nothing was changed; otherwise $DATA may be incomplete: restore another archive before using NocoDB." >&2
  exit 1
fi
echo "Restored $SELECTED into $DATA"
