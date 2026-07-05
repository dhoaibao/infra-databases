# infra-databases

A Docker Compose repository to self-host database services securely accessible remotely via Tailscale.

## Purpose

This repository organizes database services (starting with PostgreSQL and Redis) under a single structure. Each database runs as an isolated service in its own Docker container and is locked down at the OS firewall level using UFW. Access is permitted strictly through the Tailscale VPN network (`100.64.0.0/10`).

## Prerequisites

- Ubuntu VPS (or similar) with Docker, Docker Compose, and UFW installed.
- Tailscale installed and authenticated (if not, the setup script will attempt to install and initiate authentication).

## First-Time Setup

1. Clone this repository on the target VPS.
2. Run the setup script:
   ```bash
   ./scripts/setup.sh
   ```
3. The script will:
   - Check and install Tailscale if needed.
   - Configure UFW firewall rules to restrict database ports (`5432`, `6379`, etc.) to the Tailscale IP range.
   - Copy `.env.example` to `.env` if `.env` does not exist.
4. If this is a new setup, the script will warn you to populate `.env` and exit. Open `.env` and fill in the credentials:
   ```bash
   nano .env
   ```
5. Run the setup script again to launch the services:
   ```bash
   ./scripts/setup.sh
   ```

## Connecting to Databases

You cannot connect to these databases over the public internet. You must be connected to the same Tailscale network (tailnet) as the VPS.

To connect:
1. Find your server's Tailscale IPv4 address (printed by `setup.sh` or by running `tailscale ip -4`).
2. Point your database client (e.g. DBeaver, TablePlus, `psql`, `redis-cli`) to:
   - **Host:** `<Tailscale IP>`
   - **Port:** `5432` (PostgreSQL) or `6379` (Redis)
   - **Credentials:** The usernames and passwords defined in your `.env` file.

## Backup and Restore

Scripts are located in the `scripts/` directory.

### Manual Backup
To trigger backups manually for all databases:
```bash
./scripts/backup.sh
```
This script:
- Generates compressed backups in the `backups/` directory:
  - Postgres: `backups/pg_backup_YYYY-MM-DD.sql.gz`
  - Redis: `backups/redis_backup_YYYY-MM-DD.rdb`
- Deletes any backup files older than 7 days.

### Automated Backups (Cron)
To run backups automatically every day, add a cron job for the root/sudo user:
```bash
# Open crontab editor
crontab -e

# Add the following line to run backup at 2 AM every day (adjust repository path)
0 2 * * * /home/dhoaibao/Workspace/infra-databases/scripts/backup.sh > /dev/null 2>&1
```

### Manual Restore
To restore data for a database service:
```bash
./scripts/restore.sh <service_name> <backup_file_name_or_path>
```
Example:
```bash
./scripts/restore.sh postgres pg_backup_2026-07-05.sql.gz
```
- The script will prompt you for confirmation before proceeding unless the `--force` flag is supplied:
  ```bash
  ./scripts/restore.sh --force redis redis_backup_2026-07-05.rdb
  ```

---

## Adding a New Database Service

This repository is designed to scale to $N$ databases easily. Follow these steps to add a new service (e.g., `mongodb`):

### 1. Create Config Directory
Create a subfolder under `services/` for any startup SQL scripts or configuration files:
```bash
mkdir -p services/mongodb/
```

### 2. Update `docker-compose.yml`
Define a new service block using the standard patterns:
- Explicitly pin the image version.
- Load secrets/passwords using a unique prefix (e.g., `MONGO_USER`, `MONGO_PASSWORD`).
- Mount a single, named volume for data storage (e.g., `mongodb_data`).
- Expose the default port bound strictly to `${TAILSCALE_IP}`.
- Set `restart: unless-stopped`.
- Connect to `db-net`.

Example:
```yaml
  mongodb:
    image: mongo:7.0-jammy
    container_name: mongodb_db
    restart: unless-stopped
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${MONGO_USER}
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_PASSWORD}
    volumes:
      - mongodb_data:/data/db
    ports:
      - "${TAILSCALE_IP}:27017:27017"
    networks:
      - db-net
```
Remember to add the new named volume block at the bottom under `volumes:`:
```yaml
volumes:
  ...
  mongodb_data:
    driver: local
```

### 3. Update `.env.example`
Add your new service's configuration variables:
```ini
# MongoDB
MONGO_USER=
MONGO_PASSWORD=
```

### 4. Update `scripts/setup.sh`
Add the new service's port to the `PORTS` array at the top of `scripts/setup.sh` so the firewall opens Tailscale access and blocks public access:
```bash
PORTS=(5432 6379 27017)
```

### 5. Define Backup & Restore logic

#### Update `scripts/backup.sh`
1. Define a `backup_mongodb()` function:
   ```bash
   backup_mongodb() {
     echo "Starting MongoDB backup..."
     local backup_file="backups/mongodb_backup_$(date +%Y-%m-%d).gz"
     local temp_file="${backup_file}.tmp"
     
     # Pass credentials via environment variables to the container's execution context
     if docker compose exec -T -e MONGO_INITDB_ROOT_USERNAME="$MONGO_USER" -e MONGO_INITDB_ROOT_PASSWORD="$MONGO_PASSWORD" mongodb sh -c 'mongodump --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --archive --gzip' > "$temp_file"; then
       mv "$temp_file" "$backup_file"
       echo "MongoDB backup saved to $backup_file"
     else
       echo "Error: MongoDB backup failed" >&2
       rm -f "$temp_file"
       return 1
     fi
   }
   ```
2. Add `mongodb` to the `BACKUP_SERVICES` array:
   ```bash
   BACKUP_SERVICES=(postgres redis mongodb)
   ```

#### Update `scripts/restore.sh`
1. Define a `restore_mongodb()` function:
   ```bash
   restore_mongodb() {
     local file="$1"
     echo "Restoring MongoDB from $file..."
     
     # Pipe backup file to mongorestore in the container with environment credentials
     if docker compose exec -T -e MONGO_INITDB_ROOT_USERNAME="$MONGO_USER" -e MONGO_INITDB_ROOT_PASSWORD="$MONGO_PASSWORD" mongodb sh -c 'mongorestore --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --archive --gzip' < "$file"; then
       echo "MongoDB restore completed successfully."
     else
       echo "Error: MongoDB restore failed" >&2
       return 1
     fi
   }
   ```
2. Ensure the service supports restoration.
