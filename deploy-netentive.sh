#!/usr/bin/env bash
set -euo pipefail

# ==================================================================
# Netentive One-Command Deploy Script (Colima edition)
#
# Installs Colima + Docker via Homebrew, clones all repos,
# generates secrets, builds and starts the full platform.
#
# Requirements: macOS with Homebrew (brew.sh), 8GB+ RAM
#
# Usage:
#   ./deploy-netentive.sh [INSTALL_DIR]
#
# Default install dir: ~/netentive
# ==================================================================

INSTALL_DIR="${1:-$HOME/netentive}"
REPO_SAAS="https://github.com/danmcrae-dev/netentive-saas.git"
REPO_MCP="https://github.com/danmcrae-dev/netentive-mcp.git"
REPO_CORE="https://github.com/danmcrae-dev/netentive-core.git"
SAAS_PORT=8000
MCP_PORT=8443

# Colima VM sizing — adjustable via env vars
COLIMA_CPU="${COLIMA_CPU:-4}"
COLIMA_MEMORY="${COLIMA_MEMORY:-6}"
COLIMA_DISK="${COLIMA_DISK:-50}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
title() { echo -e "\n${BOLD}=== $* ===${NC}\n"; }

cat << 'BANNER'
+---------------------------------------------------------------+
|         Netentive Platform - One-Command Deploy                |
|        SaaS + MCP + Agent + PostgreSQL + Redis                 |
|        Powered by Colima (no Docker Desktop required)          |
+---------------------------------------------------------------+
BANNER

echo "  Install directory: ${INSTALL_DIR}"
echo "  SaaS port:          ${SAAS_PORT}"
echo "  MCP port:           ${MCP_PORT}"
echo "  Colima VM:          ${COLIMA_CPU} CPU, ${COLIMA_MEMORY}GB RAM, ${COLIMA_DISK}GB disk"
echo "  Platform:           $(uname -s) $(uname -m)"
echo ""

# ==================================================================
# Step 1: Install Homebrew (if missing)
# ==================================================================
title "Step 1: Checking Homebrew"

if ! command -v brew &>/dev/null; then
    info "Homebrew not found — installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to PATH for this session
    if [ -f /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -f /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi
ok "Homebrew found: $(brew --version | head -1)"

# ==================================================================
# Step 2: Install Colima + Docker CLI + docker-compose + git
# ==================================================================
title "Step 2: Installing Docker via Colima"

BREW_PACKAGES="colima docker docker-compose git"
for pkg in $BREW_PACKAGES; do
    if brew list --formula "$pkg" &>/dev/null; then
        ok "$pkg already installed"
    else
        info "Installing $pkg..."
        brew install "$pkg"
        ok "$pkg installed"
    fi
done

# Verify docker CLI is available
if ! command -v docker &>/dev/null; then
    err "docker CLI not found after brew install. Check your PATH."
    exit 1
fi
ok "Docker CLI: $(docker --version)"
ok "Compose: $(docker compose version 2>/dev/null || docker-compose --version 2>/dev/null | head -1)"

# ==================================================================
# Step 3: Start Colima VM with host networking
# ==================================================================
title "Step 3: Starting Colima VM"

# Check if Colima is already running
if colima status 2>/dev/null | grep -q "Running"; then
    ok "Colima is already running"
    # Verify host networking is enabled
    if ! docker info 2>/dev/null | grep -q "host"; then
        warn "Colima running but host networking may not be enabled — restarting with --network-address"
        colima stop
        colima start --cpu "${COLIMA_CPU}" --memory "${COLIMA_MEMORY}" --disk "${COLIMA_DISK}" --network-address
    fi
else
    info "Starting Colima VM (${COLIMA_CPU} CPU, ${COLIMA_MEMORY}GB RAM, ${COLIMA_DISK}GB disk)..."
    info "This takes 30-60 seconds on first run..."
    colima start --cpu "${COLIMA_CPU}" --memory "${COLIMA_MEMORY}" --disk "${COLIMA_DISK}" --network-address
fi

# Verify Docker daemon is responsive
if ! docker info &>/dev/null; then
    err "Docker daemon is not responding. Try: colima restart"
    exit 1
fi
ok "Docker daemon is running via Colima"

# Verify host networking works (our compose files use network_mode: host)
if docker run --rm --network host alpine sh -c "echo host-network-ok" 2>/dev/null | grep -q "host-network-ok"; then
    ok "Host networking is functional"
else
    warn "Host networking test failed — containers may not bind to localhost directly"
    warn "If this causes issues, run: colima stop && colima start --network-address"
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)  ARCH_LABEL="x86_64"  ;;
    arm64|aarch64) ARCH_LABEL="ARM64"   ;;
    *)             ARCH_LABEL="$ARCH"   ;;
esac
ok "Architecture: ${ARCH_LABEL}"

# ==================================================================
# Step 4: Clone repos
# ==================================================================
title "Step 4: Cloning repositories"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

clone_repo() {
    local name="$1" url="$2"
    if [ -d "$name" ]; then
        info "$name/ already exists — pulling latest"
        (cd "$name" && git pull --ff-only) || warn "$name pull failed, continuing with existing"
    else
        info "Cloning $name..."
        git clone --depth 1 "$url" "$name"
    fi
    ok "$name ready"
}

clone_repo "netentive-saas" "$REPO_SAAS"
clone_repo "netentive-mcp"  "$REPO_MCP"
clone_repo "netentive-core" "$REPO_CORE"

# ==================================================================
# Step 5: Generate secrets
# ==================================================================
title "Step 5: Generating configuration"

generate_fernet_key() {
    python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || \
    openssl rand -base64 32
}

generate_password() {
    openssl rand -hex 24 2>/dev/null || python3 -c "import secrets; print(secrets.token_hex(24))"
}

DB_PASSWORD="$(generate_password)"
MCP_API_KEY="$(generate_password)"
MCP_SERVICE_PASSWORD="$(generate_password)"
MCP_SECRET_KEY="$(generate_password)"
VAULT_KEY="$(generate_fernet_key)"

info "Generated DB_PASSWORD (${#DB_PASSWORD} chars)"
info "Generated MCP_API_KEY (${#MCP_API_KEY} chars)"
info "Generated VAULT_KEY (${#VAULT_KEY} chars)"

# Detect host IP for MCP agent registration
detect_host_ip() {
    local ip=""
    # macOS: get IP of default route interface
    if command -v ipconfig &>/dev/null; then
        local iface
        iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}' | head -1)
        if [ -n "$iface" ]; then
            ip=$(ipconfig getifaddr "$iface" 2>/dev/null || true)
        fi
    fi
    # Linux fallback
    if [ -z "$ip" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)
    fi
    # Final fallback — Colima VM address
    if [ -z "$ip" ]; then
        ip="127.0.0.1"
    fi
    echo "$ip"
}

HOST_IP="$(detect_host_ip)"
info "Detected host IP: ${HOST_IP}"

# ==================================================================
# Step 6: Write .env files
# ==================================================================
title "Step 6: Writing configuration"

info "Writing SaaS .env..."
SAAS_ENV="$INSTALL_DIR/netentive-saas/.env"
{
    echo "# Netentive SaaS - Auto-generated by deploy-netentive.sh"
    echo "# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo ""
    echo "# Database"
    echo "DATABASE_URL=postgresql://netentive:${DB_PASSWORD}@localhost:5432/netentive"
    echo "DB_PASSWORD=${DB_PASSWORD}"
    echo ""
    echo "# Redis"
    echo "REDIS_URL=redis://localhost:6379"
    echo "MCP_SERVICE_PASSWORD=${MCP_SERVICE_PASSWORD}"
    echo ""
    echo "# Credential Vault (AES-256 Fernet key)"
    echo "VAULT_ENCRYPTION_KEY=${VAULT_KEY}"
    echo ""
    echo "# Frontend"
    echo "FRONTEND_URL=http://localhost:${SAAS_PORT}"
} > "$SAAS_ENV"
ok "SaaS .env written"

info "Writing MCP .env..."
MCP_ENV="$INSTALL_DIR/netentive-mcp/.env"
{
    echo "# Netentive MCP - Auto-generated by deploy-netentive.sh"
    echo "# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo ""
    echo "# MCP Server"
    echo "PORT=${MCP_PORT}"
    echo "MCP_API_KEY=${MCP_API_KEY}"
    echo "MCP_SERVICE_EMAIL=service@netentive.ai"
    echo "MCP_SERVICE_PASSWORD=${MCP_SERVICE_PASSWORD}"
    echo "MCP_SECRET_KEY=${MCP_SECRET_KEY}"
    echo ""
    echo "# Agent"
    echo "AGENT_ID=agent-01"
    echo "SEGMENT_ID=default"
    echo "USE_MOCK=false"
    echo ""
    echo "# SaaS URL (for agent registration + heartbeat)"
    echo "SAAS_AGENT_URL=http://localhost:${SAAS_PORT}"
    echo "HOST_IP=${HOST_IP}"
    echo "HOST_HOSTNAME=$(hostname 2>/dev/null || echo 'netentive')"
    echo ""
    echo "# AI / Claude (optional - leave empty to disable AI chat)"
    echo "ANTHROPIC_API_KEY="
    echo ""
    echo "# Device credentials (defaults - can be overridden per-device in UI)"
    echo "DEVICE_USER=admin"
    echo "DEVICE_PASS="
} > "$MCP_ENV"
ok "MCP .env written"

# ==================================================================
# Step 7: Build and start SaaS
# ==================================================================
title "Step 7: Building and starting SaaS"

# Colima supports network_mode: host, so we use the original compose files
# directly — no patching needed.

info "Building SaaS images (this takes 3-8 minutes on first run)..."
cd "$INSTALL_DIR/netentive-saas/deployment"
docker compose up -d --build 2>&1 | tail -20

ok "SaaS containers started"

# Wait for postgres, then run migrations
info "Waiting for PostgreSQL..."
for i in 1 2 3 4 5 6 7 8 9 10; do
    if docker compose exec -T postgres pg_isready -U netentive 2>/dev/null; then
        ok "PostgreSQL is ready"
        break
    fi
    info "  Waiting... ($i/10)"
    sleep 3
done

info "Running database migrations..."
docker compose exec -T api python -m alembic upgrade head 2>&1 | tail -5
ok "Database migrations complete"

# ==================================================================
# Step 8: Build and start MCP
# ==================================================================
title "Step 8: Building and starting MCP"

mkdir -p "$INSTALL_DIR/netentive-mcp/data"
mkdir -p "$HOME/.ssh/netentive_agents"

info "Building MCP images (this takes 2-5 minutes)..."
cd "$INSTALL_DIR/netentive-mcp"
docker compose up -d --build 2>&1 | tail -20

ok "MCP containers started"

# ==================================================================
# Step 9: Health checks
# ==================================================================
title "Step 9: Health checks"

wait_for_health() {
    local url="$1" name="$2" max_tries="${3:-30}"
    for i in $(seq 1 "$max_tries"); do
        if curl -sf --max-time 5 "$url" >/dev/null 2>&1; then
            ok "$name is healthy"
            return 0
        fi
        if [ "$i" -eq 1 ]; then
            info "Waiting for $name..."
        fi
        sleep 2
    done
    err "$name did not become healthy in ${max_tries} tries"
    return 1
}

wait_for_health "http://localhost:${SAAS_PORT}/api/v1/status" "SaaS API" 30
wait_for_health "http://localhost:${MCP_PORT}/health" "MCP Server" 30

# ==================================================================
# Step 10: Show status + summary
# ==================================================================
title "Step 10: Deployment status"

echo ""
echo "  SaaS containers:"
cd "$INSTALL_DIR/netentive-saas/deployment"
docker compose ps 2>/dev/null || true

echo ""
echo "  MCP containers:"
cd "$INSTALL_DIR/netentive-mcp"
docker compose ps 2>/dev/null || true

echo ""
echo "  +---------------------------------------------------------------+"
echo "  |              Netentive is running!                             |"
echo "  +---------------------------------------------------------------+"
echo ""
echo "  SaaS Dashboard:    http://localhost:${SAAS_PORT}"
echo "  MCP Server:        http://localhost:${MCP_PORT}"
echo ""
echo "  Install directory: ${INSTALL_DIR}"
echo "  Configuration:      ${INSTALL_DIR}/netentive-saas/.env"
echo "                      ${INSTALL_DIR}/netentive-mcp/.env"
echo ""
echo "  First-time setup:"
echo "    1. Open http://localhost:${SAAS_PORT} in your browser"
echo "    2. Create an admin account (first user is auto-admin)"
echo "    3. Add your managed devices in the Devices page"
echo "    4. Credentials are synced to the MCP agent automatically"
echo ""
echo "  To stop:"
echo "    cd ${INSTALL_DIR}/netentive-saas/deployment && docker compose down"
echo "    cd ${INSTALL_DIR}/netentive-mcp && docker compose down"
echo "    colima stop   (stops the Docker VM)"
echo ""
echo "  To restart:"
echo "    colima start  (starts the Docker VM)"
echo "    cd ${INSTALL_DIR}/netentive-saas/deployment && docker compose up -d"
echo "    cd ${INSTALL_DIR}/netentive-mcp && docker compose up -d"
echo ""
echo "  To update (pull latest + rebuild):"
echo "    cd ${INSTALL_DIR}/netentive-saas && git pull && cd deployment && docker compose up -d --build"
echo "    cd ${INSTALL_DIR}/netentive-mcp && git pull && docker compose up -d --build"
echo ""
echo "  Colima VM management:"
echo "    colima status        - check VM status"
echo "    colima stop          - stop VM (frees RAM)"
echo "    colima start         - start VM (resumes containers)"
echo "    colima restart       - restart VM"
echo "    colima list          - list VMs"
echo ""