<!-- b-init-managed:start -->
# Agent Instructions

## Repository Purpose
This repository manages self-hosted database services (starting with PostgreSQL and Redis) running in Docker containers. It restricts external traffic strictly to the Tailscale VPN network (`100.64.0.0/10`) using UFW firewall rules configured during setup.

## Codebase Map
- [docker-compose.yml](file:///home/dhoaibao/Workspace/infra-databases/docker-compose.yml): Declares service blocks for PostgreSQL and Redis, their named volumes, environment configurations, and network bridge.
- [services/](file:///home/dhoaibao/Workspace/infra-databases/services/): Contains service-specific configurations (e.g. initialization SQL scripts under [postgres/init/](file:///home/dhoaibao/Workspace/infra-databases/services/postgres/init/) and [redis/redis.conf](file:///home/dhoaibao/Workspace/infra-databases/services/redis/redis.conf)).
- [scripts/](file:///home/dhoaibao/Workspace/infra-databases/scripts/): Database administration and orchestration scripts:
  - [setup.sh](file:///home/dhoaibao/Workspace/infra-databases/scripts/setup.sh): Tailscale provisioning, UFW rules config, `.env` file population, and starting the containers.
  - [backup.sh](file:///home/dhoaibao/Workspace/infra-databases/scripts/backup.sh): Performs manual or cron-scheduled database backups to [backups/](file:///home/dhoaibao/Workspace/infra-databases/backups/) and prunes backups older than 7 days.
  - [restore.sh](file:///home/dhoaibao/Workspace/infra-databases/scripts/restore.sh): Restores database services from backup archives.

## Working Rules & Safety
- **Environment Secrets**: Never commit the `.env` file or hardcode credentials. Store all variables in the local `.env` and document keys in `.env.example`.
- **Database Access Security**: Never expose ports directly to `0.0.0.0` in `docker-compose.yml`. Bound service ports exclusively to `${TAILSCALE_IP}` (e.g. `"${TAILSCALE_IP}:5432:5432"`).
- **Adding New Services**: Follow steps in [README.md](file:///home/dhoaibao/Workspace/infra-databases/README.md) to scale to new services:
  1. Pin the Docker image version.
  2. Map volume to named volume.
  3. Bind ports to `${TAILSCALE_IP}`.
  4. Allow the new port under `PORTS` array of [setup.sh](file:///home/dhoaibao/Workspace/infra-databases/scripts/setup.sh).
  5. Add corresponding `backup_<service>` and `restore_<service>` functions in [backup.sh](file:///home/dhoaibao/Workspace/infra-databases/scripts/backup.sh) and [restore.sh](file:///home/dhoaibao/Workspace/infra-databases/scripts/restore.sh).

## Verification Commands
- **Run setup and start services**:
  ```bash
  ./scripts/setup.sh
  ```
- **Trigger manual database backup**:
  ```bash
  ./scripts/backup.sh
  ```
- **Restore service data**:
  ```bash
  ./scripts/restore.sh <service_name> <backup_file_path>
  # For non-interactive/scripted restores:
  ./scripts/restore.sh --force <service_name> <backup_file_path>
  ```
- **Check service container status**:
  ```bash
  docker compose ps
  ```
<!-- b-init-managed:end -->
