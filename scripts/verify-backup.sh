#!/bin/bash
set -eo pipefail

# Restore drill: proves the newest local backups can actually be restored, without touching the
# live databases. PostgreSQL: the newest dump and its roles file are replayed into a throwaway
# container with no network, no published port and its data on tmpfs. Redis: the newest RDB is
# checked with redis-check-rdb. Run weekly by the maintenance timer; exits non-zero on any problem.
#
# Restore errors can quote row data, so their details are withheld from the output (the journal)
# unless VERIFY_DEBUG=1 is set, which is meant for a run in your own terminal.
#
# Usage: scripts/verify-backup.sh

# Change directory to the root of the repository
cd "$(dirname "$0")/.."

# Temp files hold the full database contents: keep them private to this user
umask 077

# Backups older than this mean the daily job is not producing fresh ones
MAX_AGE_HOURS=48

# Load configuration from .env
if [ -f .env ]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
else
  echo "Error: .env file not found." >&2
  exit 1
fi

if [ -z "${PG_DB:-}" ]; then
  echo "Error: PG_DB is empty in .env." >&2
  exit 1
fi

# Newest file matching a pattern (timestamps in the names sort lexicographically)
newest() {
  local latest=""
  local f
  for f in $1; do
    [ -e "$f" ] && latest="$f"
  done
  printf '%s' "$latest"
}

# Fail when a backup is missing or stale
require_fresh() {
  local file="$1" label="$2"
  if [ -z "$file" ]; then
    echo "Error: no $label backup found in backups/." >&2
    return 1
  fi
  local age_hours=$(( ( $(date +%s) - $(stat -c %Y "$file") ) / 3600 ))
  if [ "$age_hours" -gt "$MAX_AGE_HOURS" ]; then
    echo "Error: the newest $label backup ($file) is $age_hours hours old (limit $MAX_AGE_HOURS)." >&2
    return 1
  fi
  echo "Newest $label backup: $file (${age_hours}h old)"
}

# Decompress an archive completely into a temp file and require pg_dump's closing comment, so a
# truncated archive or a cut-off dump is caught before anything is replayed
unpack_complete_dump() {
  local archive="$1" out="$2" trailer="$3"
  if ! gunzip -c "$archive" > "$out"; then
    echo "Error: $archive is not a valid gzip file." >&2
    return 1
  fi
  if ! tail -n 5 "$out" | grep -q "$trailer"; then
    echo "Error: $archive is truncated (no '$trailer' trailer)." >&2
    return 1
  fi
}

PG_DUMP=$(newest "backups/pg_backup_*.sql.gz")
REDIS_DUMP=$(newest "backups/redis_backup_*.rdb")

DRILL_NAME="infra-db-drill-$$"
# A bootstrap role no source role can share: the roles replay below must not hit existing roles
DRILL_ROLE="drill_admin_$$"
DRILL_SQL=""
DRILL_GLOBALS=""
DRILL_ERR=""
cleanup() {
  docker rm -f "$DRILL_NAME" >/dev/null 2>&1 || true
  rm -f "$DRILL_SQL" "$DRILL_GLOBALS" "$DRILL_ERR"
}
trap cleanup EXIT

# Print why a restore step failed without leaking row data
explain_failure() {
  if [ "${VERIFY_DEBUG:-}" = "1" ] && [ -s "$DRILL_ERR" ]; then
    cat "$DRILL_ERR" >&2
  else
    echo "Details withheld because they can quote row data; rerun ./scripts/verify-backup.sh with VERIFY_DEBUG=1 in a terminal." >&2
  fi
}

verify_postgres() {
  echo "== PostgreSQL restore drill =="
  require_fresh "$PG_DUMP" "PostgreSQL" || return 1

  # The roles file written by the same backup run; without it a rebuilt server loses its users
  local stamp="${PG_DUMP##*pg_backup_}"
  local pg_globals="backups/pg_globals_${stamp}"
  if [ ! -f "$pg_globals" ]; then
    echo "Error: the roles backup $pg_globals that belongs to $PG_DUMP is missing." >&2
    return 1
  fi

  # Same image as the live database, so the drill exercises the version that will do the restore
  local image
  image=$(docker compose config --images | grep '^postgres:' | head -n 1 || true)
  if [ -z "$image" ]; then
    echo "Error: could not find the postgres image in docker-compose.yml." >&2
    return 1
  fi

  DRILL_SQL=$(mktemp "backups/.drill-sql.XXXXXX")
  DRILL_GLOBALS=$(mktemp "backups/.drill-globals.XXXXXX")
  DRILL_ERR=$(mktemp "backups/.drill-err.XXXXXX")
  unpack_complete_dump "$PG_DUMP" "$DRILL_SQL" 'PostgreSQL database dump complete' || return 1
  unpack_complete_dump "$pg_globals" "$DRILL_GLOBALS" 'PostgreSQL database cluster dump complete' || return 1

  echo "Starting a throwaway $image container..."
  # --log-driver none: the server logs failed statements (with row data) to its own stderr, which
  # would otherwise land in the Docker daemon's log driver (possibly the journal)
  docker run -d --name "$DRILL_NAME" --network none --log-driver none \
    --tmpfs /var/lib/postgresql/data:rw,size=2g \
    -e POSTGRES_USER="$DRILL_ROLE" -e POSTGRES_HOST_AUTH_METHOD=trust \
    "$image" >/dev/null || return 1

  # During init the server listens on the socket only, so waiting on TCP means the final server
  local tries=0
  until docker exec "$DRILL_NAME" pg_isready -h 127.0.0.1 -U "$DRILL_ROLE" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -gt 60 ]; then
      echo "Error: the throwaway PostgreSQL did not become ready." >&2
      return 1
    fi
    sleep 1
  done

  # The throwaway cluster's only role is its own bootstrap role, so nothing here may already exist: any
  # statement error means the roles backup could not rebuild the users on a fresh server
  echo "Replaying roles from $pg_globals..."
  if ! docker exec -i "$DRILL_NAME" psql -q -U "$DRILL_ROLE" -d postgres -v ON_ERROR_STOP=1 --single-transaction < "$DRILL_GLOBALS" >/dev/null 2>"$DRILL_ERR"; then
    echo "Error: the roles backup did not replay." >&2
    explain_failure
    return 1
  fi

  # PG_DB may be a database the new cluster already has (for example "postgres")
  local db_exists
  db_exists=$(printf '%s\n' "select 1 from pg_database where datname = :'db'" \
    | docker exec -i "$DRILL_NAME" psql -U "$DRILL_ROLE" -d postgres -tA -v db="$PG_DB") || return 1
  if [ -z "$db_exists" ]; then
    docker exec "$DRILL_NAME" createdb -U "$DRILL_ROLE" "$PG_DB" || return 1
  fi
  echo "Restoring $PG_DUMP..."
  if ! docker exec -i "$DRILL_NAME" psql -q -U "$DRILL_ROLE" -d "$PG_DB" -v ON_ERROR_STOP=1 --single-transaction < "$DRILL_SQL" >/dev/null 2>"$DRILL_ERR"; then
    echo "Error: the PostgreSQL dump did not restore." >&2
    explain_failure
    return 1
  fi

  local tables
  tables=$(docker exec "$DRILL_NAME" psql -U "$DRILL_ROLE" -d "$PG_DB" -tA \
    -c "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')") || return 1
  echo "PostgreSQL restore drill passed: tables=$tables"
}

verify_redis() {
  echo "== Redis backup check =="
  require_fresh "$REDIS_DUMP" "Redis" || return 1
  if ! docker compose run --rm -T --no-deps --entrypoint sh redis -eu -c '
    temp_rdb=$(mktemp)
    trap "rm -f \"$temp_rdb\"" EXIT
    cat > "$temp_rdb"
    redis-check-rdb "$temp_rdb"
  ' < "$REDIS_DUMP" >/dev/null 2>&1; then
    echo "Error: $REDIS_DUMP failed redis-check-rdb." >&2
    return 1
  fi
  echo "Redis backup check passed."
}

# Errexit is ignored inside functions called in an `||` list, so the functions use explicit
# `|| return 1`. Run both even when the first fails, so one report shows everything that is wrong
FAILED=0
verify_postgres || FAILED=1
verify_redis || FAILED=1

if [ "$FAILED" -ne 0 ]; then
  echo "Restore drill FAILED." >&2
  exit 1
fi
echo "Restore drill passed."
