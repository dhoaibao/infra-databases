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

# Ensure backups directory exists
mkdir -p backups

# PostgreSQL backup routine
backup_postgres() {
  echo "Starting PostgreSQL backup..."
  local backup_file="backups/pg_backup_$(date +%Y-%m-%d).sql.gz"
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
  local backup_file="backups/redis_backup_$(date +%Y-%m-%d).rdb"
  local temp_file="${backup_file}.tmp"
  
  # Run redis-cli --rdb in the container and stream to host, using docker compose exec -e REDISCLI_AUTH for safety
  if docker compose exec -T -e REDISCLI_AUTH="$REDIS_PASSWORD" redis redis-cli --rdb - > "$temp_file"; then
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

# Run backups for each configured service
for service in "${BACKUP_SERVICES[@]}"; do
  if declare -f "backup_$service" > /dev/null; then
    "backup_$service"
  else
    echo "Warning: No backup function defined for service: $service" >&2
  fi
done

# Prune backups older than 7 days generically (excluding .gitkeep)
echo "Pruning backups older than 7 days..."
find backups/ -type f ! -name ".gitkeep" -mtime +7 -print -delete

echo "Backup execution finished successfully."
