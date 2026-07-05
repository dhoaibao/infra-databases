# infra-databases

Self-hosted PostgreSQL and Redis services managed with Docker Compose and exposed only on a server's Tailscale IPv4 address.

## Services

| Service | Image | Port | Persistent data |
| --- | --- | --- | --- |
| PostgreSQL | `postgres:16.3-alpine` | `5432` | `postgres_data` |
| Redis | `redis:7.2.5-alpine` | `6379` | `redis_data` |

Both services use the private `db-net` bridge network. Host ports bind to `${TAILSCALE_IP}` rather than `0.0.0.0`.

## Prerequisites

- An Ubuntu server or similar Linux host
- Docker with the Compose plugin
- UFW
- Root or `sudo` access for Tailscale and firewall configuration

The setup script installs Tailscale with its official install script when the `tailscale` command is unavailable, then runs `sudo tailscale up`.

## First-time setup

Clone the repository on the server and run:

```bash
./scripts/setup.sh
```

On the first run, the script:

1. Ensures Tailscale is installed and obtains the server's Tailscale IPv4 address.
2. Allows `100.64.0.0/10` on `tailscale0` to reach ports `5432` and `6379` through UFW.
3. Copies `.env.example` to `.env` and writes `TAILSCALE_IP`.
4. Exits before starting the databases so credentials can be configured.

Edit `.env` and fill every credential:

```dotenv
TAILSCALE_IP=100.x.y.z
PG_USER=change-me
PG_PASSWORD=change-me
PG_DB=change-me
REDIS_PASSWORD=change-me
```

Never commit `.env`. Run setup again after saving it:

```bash
./scripts/setup.sh
```

The second run validates the required values and starts the stack with `docker compose up -d`.

## Connecting

The client must be connected to the same tailnet as the server.

- Host: the server's Tailscale IPv4 address (`tailscale ip -4`)
- PostgreSQL port: `5432`
- Redis port: `6379`
- Credentials: values configured in the server's `.env`

Check container state with:

```bash
docker compose ps
```

## Backups

Back up both services from the repository checkout:

```bash
./scripts/backup.sh
```

The script loads `.env`, creates `backups/` if needed, and writes:

- `backups/pg_backup_YYYY-MM-DD.sql.gz`
- `backups/redis_backup_YYYY-MM-DD.rdb`

Files older than seven days are deleted after successful backups. Running the script more than once on the same day replaces that day's files. Redis backups are first written inside the container and then streamed to the host as raw RDB data.

For a daily cron job, use the absolute path to your own checkout:

```cron
0 2 * * * /absolute/path/to/infra-databases/scripts/backup.sh >/dev/null 2>&1
```

## Restores

Restores overwrite service data. PostgreSQL checks the gzip integrity and imports the compressed SQL dump into the running database. Redis validates the RDB with `redis-check-rdb`, stops its service, replaces `/data/dump.rdb`, and starts the service again. A cleanup trap attempts to restart Redis if replacement fails.

```bash
./scripts/restore.sh <postgres|redis> <backup-file>
```

The backup may be an explicit path or a filename found under `backups/`:

```bash
./scripts/restore.sh postgres pg_backup_2026-07-05.sql.gz
./scripts/restore.sh redis backups/redis_backup_2026-07-05.rdb
```

The script asks for confirmation. Use `--force` only for intentional non-interactive restores:

```bash
./scripts/restore.sh --force postgres backups/pg_backup_2026-07-05.sql.gz
```

## Adding a database service

Keep the security and operational pieces in sync:

1. Add a version-pinned service to `docker-compose.yml` with `restart: unless-stopped`, a named data volume, the `db-net` network, and a host port bound to `${TAILSCALE_IP}`.
2. Add configuration or initialization files under `services/<service>/` when needed.
3. Add empty, documented keys to `.env.example`; keep real credentials only in `.env`.
4. Add the service port to `PORTS` in `scripts/setup.sh`.
5. Add `backup_<service>` and `restore_<service>` functions and update the relevant dispatch list.
6. Document connection details and the backup format here.

Do not expose a database port on `0.0.0.0`. Initialization files such as PostgreSQL's `services/postgres/init/01-init.sql` run only when a fresh data volume is created; they are not migrations for an existing database.

## Validation

Run non-mutating checks after configuration or script changes:

```bash
bash -n scripts/setup.sh scripts/backup.sh scripts/restore.sh
docker compose config --quiet
```
