#!/bin/bash
set -eo pipefail


# Change directory to the root of the repository
cd "$(dirname "$0")/.."

# Load credentials from .env
if [ -f .env ]; then
  # Source .env using allexport to securely preserve spaces, quotes, and symbols
  set -a
  source .env
  set +a
else
  echo "Error: .env file not found." >&2
  exit 1
fi

FORCE=false
SERVICE=""
BACKUP_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=true
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
  echo "Usage: $0 [--force] <service_name> <backup_file_path>" >&2
  echo "Example: $0 postgres pg_backup_2026-07-05.sql.gz" >&2
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

# Prompt for confirmation unless --force is specified
if [ "$FORCE" = false ]; then
  echo "WARNING: Restoring will overwrite existing data for service '$SERVICE'!"
  read -p "Are you sure you want to proceed? (y/N): " confirm
  if [[ ! "$confirm" =~ ^[yY](es)?$ ]]; then
    echo "Restore aborted."
    exit 0
  fi
fi

# PostgreSQL restore routine
restore_postgres() {
  local file="$1"
  echo "Restoring PostgreSQL database from $file..."
  
  # Decompress SQL on the host and pipe it directly to psql in the container,
  # passing PGPASSWORD via -e and using ON_ERROR_STOP=1 to halt on failures.
  if gunzip -c "$file" | docker compose exec -T -e PGPASSWORD="$PG_PASSWORD" postgres psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1; then
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
  
  # Stop the running Redis service container to avoid write conflicts
  echo "Stopping Redis container..."
  docker compose stop redis
  
  # Inject the backup RDB file into the volume using a temporary container helper
  echo "Copying backup to Redis data volume..."
  if docker compose run --rm -T --entrypoint sh redis -c 'cat > /data/dump.rdb' < "$file"; then
    echo "Redis data volume updated."
  else
    echo "Error: Failed to write RDB file to Redis volume" >&2
    echo "Restarting Redis container..."
    docker compose start redis
    return 1
  fi
  
  # Restart the Redis service container
  echo "Restarting Redis container..."
  docker compose start redis
  echo "Redis data restore completed successfully."
}

# Dispatch restore based on service name
if declare -f "restore_$SERVICE" > /dev/null; then
  "restore_$SERVICE" "$BACKUP_FILE"
else
  echo "Error: Unsupported or unknown service: $SERVICE" >&2
  exit 1
fi
