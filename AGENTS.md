<!-- b-init-managed:start -->
# Agent Instructions

## Repository Purpose
This repository runs self-hosted PostgreSQL and Redis with Docker Compose. Database ports bind only to the host's Tailscale IPv4 address, and `scripts/setup.sh` opens them in UFW for the Tailscale range (`100.64.0.0/10`) on `tailscale0`.

## Project Operating Guide

### Architecture and change map
- `docker-compose.yml`: pinned images, `${TAILSCALE_IP}` port bindings, named volumes, healthchecks (Postgres has a 30s `start_period`), json-file log rotation (`x-logging`), a 60s Postgres `stop_grace_period`, and the shared `db-net` bridge. Changing a service's definition recreates its container on the next deploy.
- `services/postgres/init/`: SQL mounted into PostgreSQL's entrypoint init directory.
- `services/redis/redis.conf`: Redis config mounted read-only; the password is passed on the command line from `REDIS_PASSWORD`.
- `scripts/setup.sh`: Tailscale detection/install, UFW rules, `.env` bootstrap and validation, `docker compose up -d --wait` (fails when a service is unhealthy).
- `scripts/backup.sh` / `scripts/restore.sh`: per-service `backup_<service>` / `restore_<service>` functions with a dispatch list; seven-day retention in `backups/`.

### Canonical sources and required change flows
- `.env.example` is the canonical key list; real values live only in the ignored `.env`. Keep new keys empty there and never print, commit, or hardcode secrets.
- `.github/workflows/deploy.yml` runs `ci.yml` first, backs up the running databases on the server with the currently deployed scripts, builds `.env` from GitHub environment secrets, copies it to the server over SSH, checks out the pushed SHA, and runs `scripts/setup.sh`. A push to `main` touching `docker-compose.yml`, `services/**`, `scripts/**`, or the workflow deploys to production; a new env key also needs a matching secret and a line in the workflow's `.env` step.
- Adding a service touches, together: its Compose definition and named volume, `services/<service>/` files, `.env.example`, the workflow `.env` step, `PORTS` in `scripts/setup.sh`, the backup/restore functions and dispatch lists, and the README service table and backup notes.

### Constraints and boundaries
- Keep images version-pinned, data in named volumes, and ports bound to `${TAILSCALE_IP}`; never bind a database to `0.0.0.0`.
- `scripts/setup.sh` has host side effects: it can install Tailscale (interactive shell only; without a TTY it exits 5), change UFW/iptables rules, rewrite `TAILSCALE_IP` in `.env`, and start containers. The deploy workflow also runs it.
- `.env` is kept at mode `600` (setup enforces it; the deploy workflow uploads `.env` to a fresh `.env.new` and moves it into place, because `scp` keeps the mode of an existing file) and `backups/` at `700` with `umask 077` in the backup and restore scripts; keep new credential or dump files private the same way.
- Restores overwrite live data, and Redis restore stops and restarts its container. A restore first saves the current data via `scripts/backup.sh --no-prune <service>` and aborts if that fails (`--skip-safety-backup` overrides); Postgres restores run in one transaction. Backups write and prune files in `backups/`.
- PostgreSQL init SQL runs only on a fresh data volume; it is not a migration mechanism for existing data.
- Scripts must run from the repository root; backup and restore change into it themselves.

### Documentation
Create and update project docs by following `docs/README.md`.

## Verification
```bash
for script in scripts/*.sh; do bash -n "$script" || break; done
shellcheck scripts/*.sh
docker compose config --quiet
```
Use `docker compose ps` only to inspect an existing deployment. `.github/workflows/ci.yml` runs the same checks (Compose with placeholder values) on pull requests, and the deploy workflow requires it to pass first. Gap: no automated tests exist.
<!-- b-init-managed:end -->
