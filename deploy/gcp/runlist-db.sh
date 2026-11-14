#!/bin/bash
# Manages the PostgreSQL container on the GCP VM "runlist-db" (Container-Optimized OS).
# setup.sh copies this file to /var/lib/runlist/runlist-db.sh. The deploy workflow and you
# (over IAP SSH) run it with sudo:
#
#   sudo bash /var/lib/runlist/runlist-db.sh install   # first time: password on stdin, creates the container
#   sudo bash /var/lib/runlist/runlist-db.sh start     # start the container if it exists (runs at boot)
#   sudo bash /var/lib/runlist/runlist-db.sh backup    # pg_dump to /var/lib/runlist/backups (keeps 10)
#   sudo bash /var/lib/runlist/runlist-db.sh reset DIR # back up, drop music_db, reload DIR/*.sql
#   sudo bash /var/lib/runlist/runlist-db.sh verify    # row counts (DIR/../queries/verify.sql of the last reset)
#
# Everything lives on the boot disk under /var/lib/runlist, which survives reboots on COS.
set -euo pipefail

BASE=/var/lib/runlist
CONTAINER=runlist-postgres
IMAGE=postgres:17-alpine
DB_USER=music
DB_NAME=music_db

psql_db() { docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" "$@"; }

wait_ready() {
  for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" pg_isready -h 127.0.0.1 -U "$DB_USER" -d postgres > /dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "PostgreSQL didn't become ready" >&2
  return 1
}

cmd_install() {
  if docker inspect "$CONTAINER" > /dev/null 2>&1; then
    echo "$CONTAINER already exists"
    return 0
  fi
  local password
  read -r password || true # no trailing newline is fine
  [ -n "$password" ] || { echo "Pass the database password on stdin" >&2; exit 1; }
  mkdir -p "$BASE/pgdata" "$BASE/backups" "$BASE/seed"
  # Tuned for an e2-micro (1 GB RAM shared with the OS). Port 5432 is published on the VM's
  # internal IP only: the VM has no external IP, and the firewall allows 10.128.0.0/9.
  docker run -d --name "$CONTAINER" --restart always \
    -p 5432:5432 \
    -e POSTGRES_USER="$DB_USER" -e POSTGRES_DB="$DB_NAME" -e POSTGRES_PASSWORD="$password" \
    -v "$BASE/pgdata:/var/lib/postgresql/data" \
    --memory 600m \
    "$IMAGE" \
    -c shared_buffers=96MB -c effective_cache_size=256MB -c work_mem=4MB \
    -c maintenance_work_mem=64MB -c max_connections=40
  wait_ready
  echo "Created $CONTAINER (empty $DB_NAME). Load the data with: reset <dir with the db/init scripts>"
}

cmd_start() {
  if docker inspect "$CONTAINER" > /dev/null 2>&1; then
    docker start "$CONTAINER" > /dev/null
    echo "$CONTAINER running"
  else
    echo "$CONTAINER not created yet (run: install)"
  fi
}

cmd_backup() {
  wait_ready
  mkdir -p "$BASE/backups"
  local file
  file="$BASE/backups/$DB_NAME-$(date -u +%Y%m%dT%H%M%SZ).dump"
  if psql_db -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1; then
    docker exec "$CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$file"
    echo "Backup: $file ($(du -h "$file" | cut -f1))"
  else
    echo "No $DB_NAME database yet, nothing to back up"
  fi
  # Keep the 10 newest backups.
  ls -1t "$BASE"/backups/*.dump 2> /dev/null | tail -n +11 | xargs -r rm -f
}

cmd_reset() {
  local dir=${1:?usage: reset <dir with 01_schema.sql, 02_data.sql>}
  ls "$dir"/*.sql > /dev/null
  cmd_backup
  # The same steps as the postgres image's first start: a fresh database, then the init
  # scripts in alphabetical order as the superuser, stopping at the first error.
  psql_db -d postgres -c "DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE)" -c "CREATE DATABASE $DB_NAME"
  for f in "$dir"/*.sql; do
    echo "Loading $(basename "$f")"
    psql_db -q -d "$DB_NAME" < "$f"
  done
  echo "Reloaded $DB_NAME from $dir"
}

cmd_verify() {
  local file=${1:-$BASE/seed/queries/verify.sql}
  psql_db -d "$DB_NAME" < "$file"
}

case "${1:-}" in
  install) cmd_install ;;
  start) cmd_start ;;
  backup) cmd_backup ;;
  reset) cmd_reset "${2:-}" ;;
  verify) cmd_verify "${2:-}" ;;
  *) echo "usage: $0 install|start|backup|reset DIR|verify [FILE]" >&2; exit 2 ;;
esac
