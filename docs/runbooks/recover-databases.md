# Recover the databases on a new server

## Purpose
Rebuild PostgreSQL and Redis from the encrypted offsite backups after the original server is lost, and check that backups are restorable before that day comes.

## Prerequisites
- A server with Docker (Compose plugin) and UFW, and shell access with `sudo`.
- This repository cloned on it.
- The values of the `.env` keys: `PG_USER`, `PG_PASSWORD`, `PG_DB`, `REDIS_PASSWORD`, all `OFFSITE_*` keys and the two `HEALTHCHECK_*` URLs. Use the **original** `PG_USER` and `PG_PASSWORD`: the roles backup restores the original password hashes and would replace a different password. `REDIS_PASSWORD` may be new. `OFFSITE_PASSWORD` is the only way to decrypt the backups; keep a copy outside the server (a password manager).
- `OFFSITE_BACKUP=true` in `.env`.

## Steps
1. Create `.env` from `.env.example` and fill in the keys above, with the original PostgreSQL credentials.
2. Start the empty stack. This installs and authenticates Tailscale on first use, so run it from an interactive shell:
   ```bash
   ./scripts/setup.sh
   ```
3. List the offsite snapshots and confirm the newest one is recent:
   ```bash
   ./scripts/offsite.sh snapshots
   ```
4. Restore the newest snapshot into a local directory:
   ```bash
   ./scripts/offsite.sh restore ./restored
   ls ./restored/backups
   ```
5. Pick the newest files in `./restored/backups` (`pg_globals_*.sql.gz`, `pg_backup_*.sql.gz`, `redis_backup_*.rdb`). Replay the PostgreSQL roles first; errors for roles that already exist are expected:
   ```bash
   gunzip -c ./restored/backups/pg_globals_<timestamp>.sql.gz | docker compose exec -T postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d postgres'
   ```
6. Restore the database, then Redis (each asks for confirmation and saves the current, empty data first):
   ```bash
   ./scripts/restore.sh postgres ./restored/backups/pg_backup_<timestamp>.sql.gz
   ./scripts/restore.sh redis ./restored/backups/redis_backup_<timestamp>.rdb
   ```
7. Copy the restored files into `backups/` so the next backup run and the restore drill see them, then re-create the systemd timers:
   ```bash
   cp -p ./restored/backups/* backups/
   ./scripts/install-timers.sh
   ```

## Verify
```bash
docker compose ps
docker compose exec -T postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\dt"'
docker compose exec -T redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli dbsize'
./scripts/verify-backup.sh
```
Both services must be `healthy`, the expected tables and keys must be present, and the drill must end with `Restore drill passed.`. Point the applications at the new server's Tailscale IP, and check from one client on the tailnet that the application's own PostgreSQL login works over the network before switching traffic.

## Check that backups are restorable (routine)
The weekly maintenance timer runs `./scripts/verify-backup.sh`. It replays the newest PostgreSQL dump and roles file into a throwaway container (no network, no published port, data on tmpfs) and runs `redis-check-rdb` on the newest Redis backup, failing if either is missing, older than 48 hours, truncated or not restorable. Run it by hand at any time; it does not touch the live databases.

## Troubleshooting
- **`Fatal: wrong password or no key found`** from restic: `OFFSITE_PASSWORD` differs from the one used when the repository was created. There is no recovery without the right password.
- **`unable to open config file ... Access Denied`**: wrong access key, secret or bucket for `OFFSITE_STORAGE`; `./scripts/offsite.sh upload` refuses to initialize a new repository in that case.
- **Restore says `safety backup failed`**: the service being restored is not running. Start it, or pass `--skip-safety-backup` when there is nothing to save.
- **Drill fails with `roles backup ... is missing`**: the newest dump has no `pg_globals_*` file with the same timestamp (for example a backup taken before roles were included); the next daily backup creates both.
- **Drill fails with `did not restore`**: the details are withheld because restore errors can quote row data. Run `VERIFY_DEBUG=1 ./scripts/verify-backup.sh` in a terminal to see them.
- **Drill fails with `hours old`**: the daily timer is not producing backups; check `systemctl list-timers 'infra-db-*'` and `journalctl -u infra-db-backup.service`.
