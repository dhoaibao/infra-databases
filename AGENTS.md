<!-- b-init-managed:start -->
# Agent Instructions

## Repository Purpose
This repository runs self-hosted PostgreSQL and Redis services with Docker Compose. Database ports bind to the host's Tailscale address, while `scripts/setup.sh` configures UFW access for the Tailscale network (`100.64.0.0/10`).

## Codebase Map
- `docker-compose.yml`: PostgreSQL and Redis images, Tailscale-only port bindings, named volumes, and the shared bridge network.
- `services/postgres/init/`: SQL mounted into PostgreSQL's entrypoint initialization directory.
- `services/redis/redis.conf`: Redis runtime configuration mounted read-only by Compose.
- `scripts/setup.sh`: Tailscale detection, UFW rules, `.env` bootstrap, credential validation, and stack startup.
- `scripts/backup.sh`: PostgreSQL and Redis backups plus seven-day retention pruning.
- `scripts/restore.sh`: Confirmed or `--force` restoration for supported services.
- `.env.example`: Canonical list of required environment keys; `.env` holds local values and is ignored.

## Working Rules
- Keep images explicitly version-pinned, persistent data in named volumes, and service ports bound to `${TAILSCALE_IP}`. Never introduce a `0.0.0.0` database binding.
- Put credentials only in `.env`; document new keys with empty values in `.env.example`. Never print, commit, or hardcode local secret values.
- When adding a service, update its Compose definition, named volume, `.env.example` keys, `PORTS` in `scripts/setup.sh`, and matching backup/restore functions and dispatch lists where applicable.
- Keep shell scripts runnable from the repository root. Backup and restore scripts already change to that directory themselves.

## Operational Safety
- Ask before running `scripts/setup.sh`: it can install Tailscale, change UFW/iptables rules, rewrite `TAILSCALE_IP` in `.env`, and start containers.
- Ask before running backup or restore commands. Backups create and prune files; restores overwrite live database data and Redis restoration stops and restarts its container.
- Ask before changing firewall rules, starting/stopping services, deleting backups or volumes, or modifying live data.
- PostgreSQL initialization SQL only runs when a fresh data directory is initialized; do not treat edits there as migrations for existing volumes.

## Verification Commands
Run the narrowest non-mutating checks relevant to the change:

```bash
bash -n scripts/setup.sh scripts/backup.sh scripts/restore.sh
docker compose config --quiet
```

Use `docker compose ps` only when checking an existing deployment. Treat setup, backup, and restore commands as operations requiring explicit approval, not validation commands.
<!-- b-init-managed:end -->
