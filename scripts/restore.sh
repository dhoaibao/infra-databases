#!/bin/bash
set -eo pipefail


# Change directory to the root of the repository
cd "$(dirname "$0")/.."

# Load credentials from .env
if [ -f .env ]; then
  # Source .env using allexport to securely preserve spaces, quotes, and symbols
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
else
  echo "Error: .env file not found." >&2
  exit 1
fi

FORCE=false
SAFETY_BACKUP=true
SERVICE=""
BACKUP_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=true
      shift
      ;;
    --skip-safety-backup)
      SAFETY_BACKUP=false
      shift
      ;;
    *)
      if [ -z "$SERVICE" ]; then
        SERVICE="$1"
      elif [ -z "$BACKUP_FILE" ]; then
        BACKUP_FILE="$1"
      else
        echo "Error: Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# Ensure service and backup file are specified
if [ -z "$SERVICE" ] || [ -z "$BACKUP_FILE" ]; then
  echo "Usage: $0 [--force] [--skip-safety-backup] <service_name> <backup_file_path>" >&2
  echo "Example: $0 postgres pg_backup_2026-07-05T020000.sql.gz" >&2
  exit 1
fi

# Resolve backup file path (check current directory first, then backups/ folder)
if [ ! -f "$BACKUP_FILE" ] && [ -f "backups/$BACKUP_FILE" ]; then
  BACKUP_FILE="backups/$BACKUP_FILE"
fi

if [ ! -f "$BACKUP_FILE" ]; then
  echo "Error: Backup file not found: $BACKUP_FILE" >&2
  exit 1
fi

case "$SERVICE" in
  postgres|redis) ;;
  *)
    echo "Error: Unsupported or unknown service: $SERVICE" >&2
    exit 1
    ;;
esac

# Prompt for confirmation unless --force is specified
if [ "$FORCE" = false ]; then
  echo "WARNING: Restoring will overwrite existing data for service '$SERVICE'!"
  read -r -p "Are you sure you want to proceed? (y/N): " confirm
  if [[ ! "$confirm" =~ ^[yY](es)?$ ]]; then
    echo "Restore aborted."
    exit 0
  fi
fi

# Save the current data before it is overwritten; a failure aborts the restore.
# Pruning is skipped so the file being restored cannot be deleted by this run.
safety_backup() {
  if [ "$SAFETY_BACKUP" = false ]; then
    echo "Skipping safety backup of current $SERVICE data (--skip-safety-backup)."
    return 0
  fi
  echo "Saving a safety backup of the current $SERVICE data..."
  if ! ./scripts/backup.sh --no-prune "$SERVICE"; then
    echo "Error: safety backup failed; nothing was restored. Fix the service, or pass --skip-safety-backup to restore without it." >&2
    return 1
  fi
}

# PostgreSQL restore routine
restore_postgres() {
  local file="$1"
  echo "Restoring PostgreSQL database from $file..."

  # Decompress fully into a private temp file first. psql cannot see a failing
  # gunzip in a pipe and would commit whatever SQL it received, so the import only
  # starts once the whole dump is known to be intact.
  RESTORE_SQL_TMP=$(mktemp "backups/.restore-sql.XXXXXX")
  trap 'rm -f "$RESTORE_SQL_TMP"' EXIT
  if ! gunzip -c "$file" > "$RESTORE_SQL_TMP"; then
    echo "Error: PostgreSQL backup is not a valid gzip file" >&2
    return 1
  fi

  safety_backup || return 1

  # Pass PGPASSWORD via -e, halt on the first error (ON_ERROR_STOP=1) and run in one
  # transaction so a failed restore rolls back instead of leaving the database
  # half-dropped.
  if docker compose exec -T -e PGPASSWORD="$PG_PASSWORD" postgres psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 --single-transaction < "$RESTORE_SQL_TMP"; then
    echo "PostgreSQL database restore completed successfully."
  else
    echo "Error: PostgreSQL database restore failed" >&2
    return 1
  fi
}

# Redis restore routine
restore_redis() {
  local file="$1"
  echo "Restoring Redis data from $file..."

  echo "Validating Redis backup..."
  if ! docker compose run --rm -T --no-deps --entrypoint sh redis -eu -c '
    temp_rdb=$(mktemp)
    trap "rm -f \"$temp_rdb\"" EXIT
    cat > "$temp_rdb"
    redis-check-rdb "$temp_rdb"
  ' < "$file"; then
    echo "Error: Redis backup is not a valid RDB file" >&2
    return 1
  fi

  safety_backup || return 1

  # Install the recovery trap before stopping Redis so an interruption cannot
  # leave the service down between the stop and trap setup.
  REDIS_NEEDS_RESTART=false
  # shellcheck disable=SC2329 # invoked indirectly by the EXIT trap below
  ensure_redis_running() {
    if [ "$REDIS_NEEDS_RESTART" = true ]; then
      echo "Ensuring Redis container is running..."
      docker compose start redis || true
    fi
  }
  trap ensure_redis_running EXIT
  REDIS_NEEDS_RESTART=true

  # Stop the running Redis service container to avoid write conflicts
  echo "Stopping Redis container..."
  docker compose stop redis

  # Inject the backup RDB file into the volume using a temporary container helper
  echo "Copying backup to Redis data volume..."
  if docker compose run --rm -T --entrypoint sh redis -c 'cat > /data/dump.rdb' < "$file"; then
    echo "Redis data volume updated."
  else
    echo "Error: Failed to write RDB file to Redis volume" >&2
    return 1
  fi

  # Restart the Redis service container
  echo "Restarting Redis container..."
  docker compose start redis
  REDIS_NEEDS_RESTART=false
  trap - EXIT
  echo "Redis data restore completed successfully."
}

# Dispatch restore based on service name
"restore_$SERVICE" "$BACKUP_FILE"
