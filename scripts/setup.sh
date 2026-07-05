#!/bin/bash
set -eo pipefail


# Database ports to protect
PORTS=(5432 6379)

echo "[1/5] Checking Tailscale installation..."
if ! command -v tailscale >/dev/null 2>&1; then
  echo "Tailscale is not installed. Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
  echo "Starting Tailscale..."
  sudo tailscale up
else
  echo "Tailscale is already installed."
fi

echo "[2/5] Configuring firewall (UFW) rules..."
for port in "${PORTS[@]}"; do
  echo "Allowing Tailscale access to port $port via UFW..."
  sudo ufw allow from 100.64.0.0/10 to any port "$port"
done

# Clean up any leftover custom DOCKER-USER iptables chains from previous versions
if sudo iptables -C DOCKER-USER -j INFRA-DB-RULES 2>/dev/null; then
  echo "Cleaning up legacy DOCKER-USER iptables rule..."
  sudo iptables -D DOCKER-USER -j INFRA-DB-RULES
fi
if sudo iptables -L INFRA-DB-RULES >/dev/null 2>&1; then
  echo "Flushing and removing legacy INFRA-DB-RULES iptables chain..."
  sudo iptables -F INFRA-DB-RULES
  sudo iptables -X INFRA-DB-RULES
fi

echo "[3/5] Setting up environment file..."
WAS_COPIED=false
if [ ! -f .env ]; then
  echo "Warning: .env file did not exist. Copied from .env.example."
  cp .env.example .env
  WAS_COPIED=true
fi

# Retrieve Tailscale IP dynamically and write it into .env
echo "Retrieving Tailscale IP..."
TAILSCALE_IP=$(tailscale ip -4)
if [ -z "$TAILSCALE_IP" ]; then
  echo "Error: Could not retrieve Tailscale IP address. Please check Tailscale status." >&2
  exit 1
fi

if grep -q "^TAILSCALE_IP=" .env; then
  sed -i "s/^TAILSCALE_IP=.*/TAILSCALE_IP=$TAILSCALE_IP/" .env
else
  echo "TAILSCALE_IP=$TAILSCALE_IP" >> .env
fi
echo "Updated TAILSCALE_IP=$TAILSCALE_IP in .env"

if [ "$WAS_COPIED" = true ]; then
  echo "CRITICAL: A new .env file was created. Please populate database credentials in .env and run this script again."
  exit 2
fi

# Source the .env file to evaluate actual values (resolving quotes, duplicates, etc.)
set -a
source .env
set +a

# Validate required variables are present and populated with non-empty values
CRITICAL_VARS=(PG_USER PG_PASSWORD PG_DB REDIS_PASSWORD)
MISSING_OR_EMPTY=false
for var in "${CRITICAL_VARS[@]}"; do
  # Retrieve variable value dynamically
  val="${!var}"
  if [ -z "$val" ]; then
    echo "CRITICAL: Environment variable '$var' is missing or empty in .env" >&2
    MISSING_OR_EMPTY=true
  fi
done

if [ "$MISSING_OR_EMPTY" = true ]; then
  echo "CRITICAL: Setup aborted due to missing or empty database credentials in .env." >&2
  exit 3
fi

echo "[4/5] Launching docker compose services..."
docker compose up -d

echo "[5/5] Retrieving server's Tailscale IP..."
TAILSCALE_IP=$(tailscale ip -4)
echo "===================================================="
echo "Setup finished successfully!"
echo "Server Tailscale IP: $TAILSCALE_IP"
echo "Databases are accessible only via this IP."
echo "===================================================="
