#!/bin/bash
set -eo pipefail

# Installs (or removes) the systemd timers that run scripts/scheduled.sh. Run it once on the
# server as the user that owns this checkout; it calls sudo itself for the system-wide parts.
#
# Usage: scripts/install-timers.sh [--uninstall] [--dest DIR]
#   --dest DIR  only write the rendered unit files into DIR (no sudo, no systemctl); to review them

# Change directory to the root of the repository
cd "$(dirname "$0")/.."

DEST=/etc/systemd/system
SYSTEM_INSTALL=true
UNINSTALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall)
      UNINSTALL=true
      shift
      ;;
    --dest)
      DEST="${2:-}"
      SYSTEM_INSTALL=false
      if [ -z "$DEST" ]; then
        echo "Error: --dest needs a directory." >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "Usage: $0 [--uninstall] [--dest DIR]" >&2
      exit 1
      ;;
  esac
done

UNITS=(infra-db-backup.service infra-db-backup.timer infra-db-maintenance.service infra-db-maintenance.timer)
TIMERS=(infra-db-backup.timer infra-db-maintenance.timer)

if [ "$UNINSTALL" = true ]; then
  if [ "$SYSTEM_INSTALL" = false ]; then
    echo "Error: --uninstall cannot be combined with --dest." >&2
    exit 1
  fi
  sudo systemctl disable --now "${TIMERS[@]}" || true
  for unit in "${UNITS[@]}"; do
    sudo rm -f "$DEST/$unit"
  done
  sudo systemctl daemon-reload
  echo "Timers removed."
  exit 0
fi

if [ "$(id -u)" -eq 0 ]; then
  echo "Error: run this as the user that owns the checkout, not as root (it calls sudo itself)." >&2
  exit 1
fi

REPO_DIR=$(pwd)
RUN_USER=$(id -un)
# The values end up in unit files; keep them free of characters systemd would interpret
if [[ ! "$REPO_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || [[ ! "$RUN_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Error: the checkout path and user name may only contain letters, digits, '.', '_', '-' (and '/' in the path)." >&2
  exit 1
fi

if [ "$SYSTEM_INSTALL" = true ]; then
  # Fail before touching /etc if the services could not run anyway
  if ! docker compose version >/dev/null 2>&1; then
    echo "Error: 'docker compose' is not usable by user '$RUN_USER'." >&2
    exit 1
  fi
else
  mkdir -p "$DEST"
fi

for unit in "${UNITS[@]}"; do
  rendered=$(sed -e "s|@USER@|$RUN_USER|g" -e "s|@DIR@|$REPO_DIR|g" "systemd/$unit")
  if [ "$SYSTEM_INSTALL" = true ]; then
    printf '%s\n' "$rendered" | sudo tee "$DEST/$unit" >/dev/null
    sudo chmod 644 "$DEST/$unit"
  else
    printf '%s\n' "$rendered" > "$DEST/$unit"
  fi
  echo "Wrote $DEST/$unit"
done

if [ "$SYSTEM_INSTALL" = true ]; then
  sudo systemctl daemon-reload
  sudo systemctl enable --now "${TIMERS[@]}"
  echo "Timers enabled. Next runs:"
  systemctl list-timers "${TIMERS[@]}" --no-pager
fi
