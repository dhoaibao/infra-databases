# ADR-001: Backup and recovery design

- Status: Accepted
- Date: 2026-10-08
- Supersedes: none

## Context
The stack is one self-hosted server running PostgreSQL and Redis in Docker Compose, reachable only over Tailscale. Before this decision backups were a hand-run script writing to the same disk, with no schedule, no alert on failure, no offsite copy, and a restore that could leave PostgreSQL half-overwritten. Losing the disk, or one bad restore, meant losing the data.

## Decision
- **Backups stay logical and daily.** `pg_dump` (plus `pg_dumpall --globals-only` for roles) and Redis RDB, written to a private `backups/` directory with timestamped names. The recovery point objective stays 24 hours; there is no WAL archiving or Redis AOF. Redis is treated as data that may lose up to a day.
- **Offsite copy with restic, selected by environment.** `scripts/offsite.sh` runs a pinned restic container and is turned on with `OFFSITE_BACKUP=true`; `OFFSITE_STORAGE` is `s3`, `r2` (Cloudflare R2) or `oss` (Alibaba Cloud OSS), and any other S3-compatible store works through `s3` with an endpoint. Restic encrypts on the client, so the provider never sees plaintext. Restic was chosen over rclone because it provides encryption, snapshots, retention and restore in one tool and runs from a container image.
- **Offsite is separate from local backup and restore.** `upload` never prunes; `prune`/`check` run weekly. An offsite outage cannot block a deploy's pre-deploy backup or a restore.
- **systemd timers, not cron or CI.** `infra-db-backup.timer` (daily) and `infra-db-maintenance.timer` (weekly) run `scripts/scheduled.sh`, so missed runs catch up after a reboot and logs go to the journal. They are installed once by hand with `scripts/install-timers.sh`.
- **healthchecks.io as a dead man's switch.** Each job pings `/start`, then success or `/fail`; a job that never runs sends nothing and the service reports it late. The ping URLs are secrets.
- **Safe operations around the data.** Every deploy takes a backup first and fails if it cannot; `docker compose up --wait` fails the deploy on unhealthy services; every restore saves the current data first and imports PostgreSQL in one transaction; a weekly drill restores the newest dump and its roles file into a throwaway container and withholds restore error details (they can quote row data) from the journal.

## Consequences
- Up to 24 hours of data can be lost, and a host failure also loses everything since the last offsite upload.
- The restic repository password is a single point of failure for the offsite copy and must be stored outside the server.
- A server key that can delete can also erase offsite backups; scoped keys and provider object lock reduce that but are not set up by this repository.
- The `oss` addressing options and R2 behavior were not exercised against live providers when this was written; run `./scripts/offsite.sh upload`, `check` and `restore` once after configuring a real bucket.
- Deferred until there is a demonstrated need: PITR with WAL archiving, Redis AOF, replication or failover, container resource limits, Postgres tuning, a least-privilege application role, and SSH over Tailscale for deploys.
