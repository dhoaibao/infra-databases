#!/bin/bash
set -eo pipefail


# Change directory to the root of the repository
cd "$(dirname "$0")/.."

# Dumps hold the full database contents: keep new files private to this user
umask 077

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

# Ensure backups directory exists and is private (also tightens a pre-existing one)
mkdir -p backups
chmod 700 backups

# Serialize runs (cron vs. pre-deploy) so they never write the same files; the lock is
# released when the script exits.
exec 9> backups/.backup.lock
flock 9

# One timestamp per run keeps same-day backups from overwriting each other. Runs are
# serialized above, so waiting for a free second guarantees unique file names.
BACKUP_TIMESTAMP=$(date +%Y-%m-%dT%H%M%S)
while compgen -G "backups/*_backup_${BACKUP_TIMESTAMP}.*" > /dev/null; do
  sleep 1
  BACKUP_TIMESTAMP=$(date +%Y-%m-%dT%H%M%S)
done

# PostgreSQL backup routine
backup_postgres() {
  echo "Starting PostgreSQL backup..."
  local backup_file="backups/pg_backup_${BACKUP_TIMESTAMP}.sql.gz"
  local temp_file="${backup_file}.tmp"
  
  # Run pg_dump within the container with credentials passed as environment variables via docker compose exec -e,
  # including --clean and --if-exists options to ensure clean overwrite on restores.
  if docker compose exec -T -e PGPASSWORD="$PG_PASSWORD" postgres pg_dump -U "$PG_USER" -d "$PG_DB" --clean --if-exists | gzip > "$temp_file"; then
    mv "$temp_file" "$backup_file"
    echo "PostgreSQL backup saved to $backup_file"
  else
    echo "Error: PostgreSQL backup failed" >&2
    rm -f "$temp_file"
    return 1
  fi
}

# Redis backup routine
backup_redis() {
  echo "Starting Redis backup..."
  local backup_file="backups/redis_backup_${BACKUP_TIMESTAMP}.rdb"
  local temp_file="${backup_file}.tmp"

  # redis-cli expects --rdb to name a file; it does not define "-" as stdout.
  # Create the RDB in the container, then stream only its bytes to the host.
  if docker compose exec -T -e REDISCLI_AUTH="$REDIS_PASSWORD" redis sh -eu -c '
    temp_rdb=$(mktemp)
    trap "rm -f \"$temp_rdb\"" EXIT
    redis-cli --rdb "$temp_rdb" >&2
    cat "$temp_rdb"
  ' > "$temp_file"; then
    mv "$temp_file" "$backup_file"
    echo "Redis backup saved to $backup_file"
  else
    echo "Error: Redis backup failed" >&2
    rm -f "$temp_file"
    return 1
  fi
}

# List of active database backup routines
BACKUP_SERVICES=(postgres redis)

# Usage: backup.sh [--no-prune] [service...]  (default: every configured service)
PRUNE=true
REQUESTED_SERVICES=()
for arg in "$@"; do
  case "$arg" in
    --no-prune) PRUNE=false ;;
    *) REQUESTED_SERVICES+=("$arg") ;;
  esac
done

if [ "${#REQUESTED_SERVICES[@]}" -gt 0 ]; then
  for service in "${REQUESTED_SERVICES[@]}"; do
    if ! declare -f "backup_$service" > /dev/null; then
      echo "Error: Unknown service: $service" >&2
      exit 1
    fi
  done
  BACKUP_SERVICES=("${REQUESTED_SERVICES[@]}")
fi

# Run backups for each selected service
for service in "${BACKUP_SERVICES[@]}"; do
  if declare -f "backup_$service" > /dev/null; then
    "backup_$service"
  else
    echo "Warning: No backup function defined for service: $service" >&2
  fi
done

# Prune backups older than 7 days generically (excluding .gitkeep and the lock file)
if [ "$PRUNE" = true ]; then
  echo "Pruning backups older than 7 days..."
  find backups/ -type f ! -name ".gitkeep" ! -name ".backup.lock" -mtime +7 -print -delete
fi

echo "Backup execution finished successfully."
