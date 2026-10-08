#!/bin/bash
set -eo pipefail

# Entry point for the systemd timers (see systemd/ and scripts/install-timers.sh).
# Runs one job and reports the result to healthchecks.io: a /start ping, then a success ping
# or a /fail ping. A job that never runs sends nothing, which healthchecks.io reports as late.
#
# Usage: scripts/scheduled.sh <backup|maintenance>
#   backup       local backup, then the offsite upload (HEALTHCHECK_URL)
#   maintenance  offsite retention and integrity check, then the local restore drill
#                (HEALTHCHECK_MAINTENANCE_URL)

# Change directory to the root of the repository
cd "$(dirname "$0")/.."

JOB="${1:-}"
case "$JOB" in
  backup|maintenance) ;;
  *)
    echo "Usage: $0 <backup|maintenance>" >&2
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

# The ping URL is a secret (anyone holding it can send pings): never print it
case "$JOB" in
  backup) PING_URL="${HEALTHCHECK_URL:-}" ;;
  maintenance) PING_URL="${HEALTHCHECK_MAINTENANCE_URL:-}" ;;
esac

# The URL is written into a curl config on stdin: unlike an argument it never shows up in `ps`.
# It is restricted to characters that are safe inside that quoted config value, and curl's own
# diagnostics are discarded because they can quote the URL.
if [ -n "$PING_URL" ] && [[ ! "$PING_URL" =~ ^https?://[A-Za-z0-9._~:/?#@!\$\&\'\(\)*+,\;=%-]+$ ]]; then
  echo "Warning: the monitoring URL for '$JOB' is not a plain http(s) URL; monitoring is disabled for this run." >&2
  PING_URL=""
fi

# A monitoring outage must not fail the job itself
ping_monitor() {
  [ -n "$PING_URL" ] || return 0
  if ! printf 'url = "%s%s"\n' "${PING_URL%/}" "$1" | curl -q -K - --globoff -fs -m 10 --retry 3 -o /dev/null 2>/dev/null; then
    echo "Warning: could not reach the monitoring service (ping '$1')." >&2
  fi
}

# Explicit `|| return $?` (keeps the failing exit code) instead of `set -e`: errexit is ignored while this runs as an `if` condition
run_job() {
  case "$JOB" in
    backup)
      ./scripts/backup.sh || return $?
      ./scripts/offsite.sh upload || return $?
      ;;
    maintenance)
      ./scripts/offsite.sh prune || return $?
      ./scripts/offsite.sh check || return $?
      ./scripts/verify-backup.sh || return $?
      ;;
  esac
}

echo "Starting scheduled job: $JOB"
ping_monitor /start
if run_job; then
  ping_monitor ""
  echo "Scheduled job '$JOB' finished successfully."
else
  status=$?
  echo "Error: scheduled job '$JOB' failed." >&2
  ping_monitor /fail
  exit "$status"
fi
