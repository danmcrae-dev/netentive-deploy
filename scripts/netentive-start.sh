#!/bin/bash
# Netentive auto-start script — called by launchd/systemd/Task Scheduler on login
# Starts the Docker runtime (platform-specific) + all containers
LOG=/tmp/netentive-startup.log
NETENTIVE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[$(date)] Netentive startup beginning..." >> "$LOG"

# Start Docker runtime based on platform
OS_TYPE="$(uname -s)"
if [[ "$OS_TYPE" == "Darwin" ]]; then
    # macOS: start Colima if not running
    if ! colima status 2>/dev/null | grep -q "Running"; then
        echo "[$(date)] Starting Colima..." >> "$LOG"
        colima start >> "$LOG" 2>&1
    else
        echo "[$(date)] Colima already running" >> "$LOG"
    fi
    # Add routes to all private networks so containers can reach remote hosts
    # (MCP agent SSH to devices, remote Ollama, multi-subset networks)
    COLIMA_GW=$(colima ssh < /dev/null -- ip route show default 2>/dev/null | grep col0 | awk '{print $3}' | head -1)
    if [ -n "$COLIMA_GW" ]; then
        for CIDR in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
            colima ssh < /dev/null -- sudo ip route add "$CIDR" via "$COLIMA_GW" dev col0 2>/dev/null
        done
        echo "[$(date)] Colima private network routes added via $COLIMA_GW" >> "$LOG"
    fi
elif [[ "$OS_TYPE" == "Linux" ]] && ! grep -qi microsoft /proc/version 2>/dev/null; then
    # Native Linux: ensure Docker service is running
    sudo systemctl start docker 2>/dev/null || true
    echo "[$(date)] Docker service started" >> "$LOG"
fi
# WSL2: Docker Desktop handles Docker lifecycle, nothing to do

# Wait for Docker daemon
for i in $(seq 1 30); do
    if docker info &>/dev/null; then
        echo "[$(date)] Docker daemon ready" >> "$LOG"
        break
    fi
    sleep 2
done

if ! docker info &>/dev/null; then
    echo "[$(date)] ERROR: Docker daemon not responding after 60s" >> "$LOG"
    exit 1
fi

# Start SaaS containers
SAAS_DEPLOY="$NETENTIVE_DIR/netentive-saas/deployment"
if [[ -f "$SAAS_DEPLOY/../.env" ]]; then
    echo "[$(date)] Starting SaaS containers..." >> "$LOG"
    cd "$SAAS_DEPLOY"
    set -a; source ../.env; set +a
    docker compose up -d >> "$LOG" 2>&1
else
    echo "[$(date)] WARN: SaaS .env not found, skipping" >> "$LOG"
fi

# Start MCP containers
MCP_DEPLOY="$NETENTIVE_DIR/netentive-mcp/deployment"
if [[ -f "$MCP_DEPLOY/../.env" ]]; then
    echo "[$(date)] Starting MCP containers..." >> "$LOG"
    cd "$MCP_DEPLOY"
    set -a; source ../.env; set +a
    docker compose up -d >> "$LOG" 2>&1
else
    echo "[$(date)] WARN: MCP .env not found, skipping" >> "$LOG"
fi

# Wait for health checks
for i in $(seq 1 30); do
    SAAS_OK=$(curl -s --connect-timeout 2 http://localhost:8000/api/v1/status 2>/dev/null | grep -o '"status":"healthy"')
    MCP_OK=$(curl -s --connect-timeout 2 http://localhost:8443/health 2>/dev/null | grep -o '"status":"ok"')
    if [[ -n "$SAAS_OK" ]]; then
        echo "[$(date)] SaaS API healthy" >> "$LOG"
    fi
    if [[ -n "$MCP_OK" ]]; then
        echo "[$(date)] MCP server healthy" >> "$LOG"
    fi
    if [[ -n "$SAAS_OK" && -n "$MCP_OK" ]]; then
        break
    fi
    sleep 3
done

echo "[$(date)] Netentive startup complete" >> "$LOG"