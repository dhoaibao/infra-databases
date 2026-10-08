#!/bin/bash
set -eo pipefail

# Encrypted offsite copy of backups/ with restic, run in a pinned container (the `offsite`
# service in docker-compose.yml). Provider-neutral: OFFSITE_STORAGE picks s3, r2 or oss.
#
# Usage: scripts/offsite.sh <upload|prune|check|snapshots|restore <dir>>

# Change directory to the root of the repository
cd "$(dirname "$0")/.."

# Repository and temp files hold credentials or dumps: keep them private to this user
umask 077

COMMAND="${1:-}"
case "$COMMAND" in
  upload|prune|check|snapshots) ;;
  restore)
    RESTORE_DIR="${2:-}"
    if [ -z "$RESTORE_DIR" ]; then
      echo "Usage: $0 restore <target_dir>" >&2
      exit 1
    fi
    ;;
  *)
    echo "Usage: $0 <upload|prune|check|snapshots|restore <target_dir>>" >&2
    exit 1
    ;;
esac

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

if [ "${OFFSITE_BACKUP:-}" != "true" ]; then
  echo "Offsite backup is disabled (OFFSITE_BACKUP is not 'true'); nothing to do."
  exit 0
fi

# Every storage needs these; endpoint and region depend on the provider (see below)
REQUIRED_VARS=(OFFSITE_STORAGE OFFSITE_BUCKET OFFSITE_ACCESS_KEY_ID OFFSITE_SECRET_ACCESS_KEY OFFSITE_PASSWORD)
case "${OFFSITE_STORAGE:-}" in
  s3) REQUIRED_VARS+=(OFFSITE_REGION) ;;
  r2) REQUIRED_VARS+=(OFFSITE_ENDPOINT) ;;
  oss) REQUIRED_VARS+=(OFFSITE_ENDPOINT OFFSITE_REGION) ;;
  *)
    echo "Error: OFFSITE_STORAGE must be one of: s3, r2, oss (got '${OFFSITE_STORAGE:-}')." >&2
    exit 1
    ;;
esac

MISSING=false
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "Error: $var is required for OFFSITE_STORAGE=$OFFSITE_STORAGE." >&2
    MISSING=true
  fi
done
if [ "$MISSING" = true ]; then
  exit 1
fi

# Endpoint is a bare host ("host[:port]", https assumed) or a full http(s):// URL.
# The bucket may carry a path prefix ("bucket/databases").
endpoint_url() {
  case "$1" in
    http://*|https://*) printf '%s' "${1%/}" ;;
    *) printf 'https://%s' "${1%/}" ;;
  esac
}

RESTIC_OPTS=(--no-cache)
case "$OFFSITE_STORAGE" in
  s3)
    RESTIC_REPOSITORY="s3:$(endpoint_url "${OFFSITE_ENDPOINT:-s3.${OFFSITE_REGION}.amazonaws.com}")/${OFFSITE_BUCKET}"
    ;;
  r2)
    RESTIC_REPOSITORY="s3:$(endpoint_url "$OFFSITE_ENDPOINT")/${OFFSITE_BUCKET}"
    OFFSITE_REGION="${OFFSITE_REGION:-auto}"
    ;;
  oss)
    RESTIC_REPOSITORY="s3:$(endpoint_url "$OFFSITE_ENDPOINT")/${OFFSITE_BUCKET}"
    # Alibaba OSS accepts only virtual-hosted-style addressing
    RESTIC_OPTS+=(-o s3.bucket-lookup=dns -o "s3.region=${OFFSITE_REGION}")
    ;;
esac
# Read by the `offsite` service through Compose interpolation
export RESTIC_REPOSITORY OFFSITE_REGION

# Backups are mounted read-only at /backups inside the container
run_restic() {
  docker compose --profile tools run --rm -T "${RUN_ARGS[@]}" offsite "${RESTIC_OPTS[@]}" "$@"
}
RUN_ARGS=()

# Retention for `prune` (the `upload` command never forgets or prunes snapshots)
KEEP_ARGS=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)

case "$COMMAND" in
  upload)
    # Exit code 10 means "repository does not exist yet"; anything else is a real error
    set +e
    probe_err=$(run_restic cat config 2>&1 >/dev/null)
    probe_rc=$?
    set -e
    if [ "$probe_rc" -eq 10 ]; then
      echo "Offsite repository not found; initializing it..."
      run_restic init
    elif [ "$probe_rc" -ne 0 ]; then
      echo "Error: cannot open the offsite repository (restic exit $probe_rc):" >&2
      echo "$probe_err" >&2
      exit 1
    fi
    echo "Uploading backups/ to the offsite repository..."
    run_restic backup /backups --host infra-databases --tag scheduled \
      --exclude '.backup.lock' --exclude '*.tmp' --exclude '.restore-sql.*'
    echo "Offsite upload finished."
    ;;
  prune)
    echo "Applying offsite retention (${KEEP_ARGS[*]})..."
    run_restic forget --prune --host infra-databases "${KEEP_ARGS[@]}"
    ;;
  check)
    echo "Checking the offsite repository (structure plus a 5% data sample)..."
    run_restic check --read-data-subset=5%
    ;;
  snapshots)
    run_restic snapshots
    ;;
  restore)
    mkdir -p "$RESTORE_DIR"
    RESTORE_DIR=$(cd "$RESTORE_DIR" && pwd)
    RUN_ARGS=(--user "$(id -u):$(id -g)" -v "$RESTORE_DIR:/restore")
    echo "Restoring the latest offsite snapshot into $RESTORE_DIR..."
    run_restic restore latest --host infra-databases --target /restore
    echo "Restore finished; the files are under $RESTORE_DIR/backups."
    ;;
esac
