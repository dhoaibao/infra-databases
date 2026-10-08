# infra-databases

Self-hosted PostgreSQL and Redis services managed with Docker Compose and exposed only on a server's Tailscale IPv4 address.

## Services

| Service | Image | Port | Persistent data |
| --- | --- | --- | --- |
| PostgreSQL | `postgres:16.3-alpine` | `5432` | `postgres_data` |
| Redis | `redis:7.2.5-alpine` | `6379` | `redis_data` |

Both services use the private `db-net` bridge network. Host ports bind to `${TAILSCALE_IP}` rather than `0.0.0.0`. Container logs rotate (three files of 10 MB per service), and PostgreSQL gets 60 seconds to shut down cleanly before Docker kills it.

## Prerequisites

- An Ubuntu server or similar Linux host
- Docker with the Compose plugin
- UFW
- Root or `sudo` access for Tailscale and firewall configuration

The setup script installs Tailscale with its official install script when the `tailscale` command is unavailable, then runs `sudo tailscale up`. This needs an interactive terminal for the login; a non-interactive run (such as the deploy workflow) exits with an error instead, so run `./scripts/setup.sh` once by hand on a new server.

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

Never commit `.env`. Setup restricts it to mode `600`. Run setup again after saving it:

```bash
./scripts/setup.sh
```

The second run validates the required values and starts the stack with `docker compose up -d --wait`, which fails if a service does not become healthy within 180 seconds.

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

- `backups/pg_backup_YYYY-MM-DDTHHMMSS.sql.gz`
- `backups/pg_globals_YYYY-MM-DDTHHMMSS.sql.gz` (cluster-wide roles with their password hashes, which `pg_dump` does not include)
- `backups/redis_backup_YYYY-MM-DDTHHMMSS.rdb`

The `backups/` directory is set to mode `700` and new files are created `600`, because dumps contain the full data. Both files from one run share a timestamp, so runs on the same day never overwrite each other. Files older than seven days are deleted after successful backups. The deploy workflow runs this script on the server before it changes anything, so a failed backup stops the deploy; it is skipped when PostgreSQL is not running (first deploy). Redis backups are first written inside the container and then streamed to the host as raw RDB data. `./scripts/backup.sh [--no-prune] [postgres|redis]` limits a run to one service and can skip pruning.

For a daily cron job, use the absolute path to your own checkout:

```cron
0 2 * * * /absolute/path/to/infra-databases/scripts/backup.sh >/dev/null 2>&1
```

## Offsite backups

`scripts/offsite.sh` keeps an encrypted copy of `backups/` outside the server, so losing the host does not lose the backups. It uses [restic](https://restic.net/) in a pinned container (the `offsite` service, in the `tools` profile, which `docker compose up` never starts) and is disabled unless `OFFSITE_BACKUP=true`. Settings live in `.env`; for deploys, add each key as a GitHub environment secret (unset secrets become empty values, which keeps the feature off).

| Key | Meaning |
| --- | --- |
| `OFFSITE_BACKUP` | `true` enables the feature |
| `OFFSITE_STORAGE` | `s3` (AWS), `r2` (Cloudflare R2) or `oss` (Alibaba Cloud OSS) |
| `OFFSITE_BUCKET` | Bucket name; may include a path prefix such as `my-bucket/databases` |
| `OFFSITE_ENDPOINT` | Host or full `http(s)://` URL. Required for `r2` (`<account-id>.r2.cloudflarestorage.com`) and `oss` (for example `oss-eu-west-1.aliyuncs.com`); optional for `s3`, which defaults to `s3.<region>.amazonaws.com` |
| `OFFSITE_REGION` | Required for `s3` and `oss`; `r2` defaults to `auto` |
| `OFFSITE_ACCESS_KEY_ID`, `OFFSITE_SECRET_ACCESS_KEY` | Storage credentials |
| `OFFSITE_PASSWORD` | Encrypts the repository. If it is lost the backups cannot be read, so keep a copy somewhere other than this server |

Any other S3-compatible store (Backblaze B2, Hetzner Object Storage, Wasabi, MinIO, and so on) works with `OFFSITE_STORAGE=s3` plus `OFFSITE_ENDPOINT` and a region.

```bash
./scripts/offsite.sh upload      # copy backups/ (creates the repository on first use; never forgets or prunes snapshots)
./scripts/offsite.sh prune       # keep 7 daily, 4 weekly and 6 monthly snapshots, delete the rest
./scripts/offsite.sh check       # verify the repository structure and a 5% sample of the data
./scripts/offsite.sh snapshots   # list snapshots
./scripts/offsite.sh restore /path/to/dir   # restore the latest snapshot into /path/to/dir/backups
```

`upload` never runs `forget` or `prune`, so it does not delete snapshots or data. Restic still needs read, list and write access, plus delete permission for its short-lived lock files under `locks/`. If your provider supports prefix-scoped policies, give the server's key delete rights only on `locks/` and run `prune` with a broader key from another machine; otherwise the server's key can erase backups, so enable object versioning or object lock at the provider and exempt `locks/` from retention (restic must be able to remove its locks). These scoped policies have not been exercised against a real provider. Restic compresses and deduplicates itself, but the dumps are already gzip-compressed, so expect little deduplication between snapshots.

To recover on a new machine: clone the repository, create `.env` with the `OFFSITE_*` keys (and the database keys), run `./scripts/offsite.sh restore ./restored`, then restore from the files in `./restored/backups` as described below.

## Restores

Restores overwrite service data. After validating the backup file, the script first saves the current data of that service with `scripts/backup.sh --no-prune <service>` (a new timestamped file in `backups/`, never pruned by the restore) and aborts if that fails. PostgreSQL decompresses the whole dump into a temporary file first (so a damaged archive is rejected before anything changes) and imports it into the running database in a single transaction, so a failed import rolls back and leaves the previous data intact. Redis validates the RDB with `redis-check-rdb`, stops its service, replaces `/data/dump.rdb`, and starts the service again. A cleanup trap attempts to restart Redis if replacement fails.

```bash
./scripts/restore.sh <postgres|redis> <backup-file>
```

The backup may be an explicit path or a filename found under `backups/`:

```bash
./scripts/restore.sh postgres pg_backup_2026-07-05T020000.sql.gz
./scripts/restore.sh redis backups/redis_backup_2026-07-05T020000.rdb
```

The script asks for confirmation. Use `--force` only for intentional non-interactive restores:

```bash
./scripts/restore.sh --force postgres backups/pg_backup_2026-07-05T020000.sql.gz
```

`restore.sh` restores the database only. On a rebuilt server, replay the roles first (errors for roles that already exist, such as the bootstrap `PG_USER`, are expected):

```bash
gunzip -c backups/pg_globals_2026-07-05T020000.sql.gz | docker compose exec -T postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d postgres'
```

Run it from the repository root; it reads the credentials from the container, so nothing needs to be exported in your shell.

If the service is down and the safety backup cannot run, add `--skip-safety-backup` to restore without it. The current data is then not saved.

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
for script in scripts/*.sh; do bash -n "$script" || break; done
shellcheck scripts/*.sh
docker compose config --quiet
```

The same checks run in `.github/workflows/ci.yml` on pull requests, and the deploy workflow requires them to pass before it connects to the server.
