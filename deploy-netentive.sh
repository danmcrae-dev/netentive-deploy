#!/usr/bin/env bash
set -euo pipefail

# ==================================================================
# Netentive One-Command Deploy Script (multi-platform edition)
#
# Supports:
#   - macOS  (Colima + Docker via Homebrew)
#   - Linux  (Docker CE via apt-get, native)
#   - WSL2   (Docker Desktop with WSL2 backend)
#
# Clones all repos, generates secrets, builds and starts the
# full platform (SaaS + MCP + Agent + PostgreSQL + Redis).
#
# Usage: curl -fsSL https://raw.githubusercontent.com/danmcrae-dev/netentive-deploy/main/deploy-netentive.sh | bash -s -- --key NET-XXXX-XXXX-XXXX
# Or:   ./deploy-netentive.sh --key NET-XXXX-XXXX-XXXX
#
# Optional flags:
#   --key NET-XXXX-XXXX-XXXX   Deployment key (required)
#   --key-server URL           Key server URL (default: https://keys.netentive.io)
#   --install-dir PATH         Install directory (default: ~/netentive)
#
# Env vars:
#   KEY_SERVER_URL             Override key server URL
#   COLIMA_CPU, COLIMA_MEMORY, COLIMA_DISK  Colima VM sizing (macOS only)
# ==================================================================

# ------------------------------------------------------------------
# If running via pipe (curl | bash), save to temp file and re-exec
# so stdin is free for commands like colima ssh that read stdin.
# ------------------------------------------------------------------
if [[ ! -t 0 && "${0}" == "bash" ]]; then
    TMP_SCRIPT="/tmp/netentive-deploy-$$.sh"
    cat > "$TMP_SCRIPT"
    chmod +x "$TMP_SCRIPT"
    exec bash "$TMP_SCRIPT" "$@"
fi

# ------------------------------------------------------------------
# Parse command-line arguments (must happen before anything else)
# ------------------------------------------------------------------
LICENSE_KEY=""
KEY_SERVER_URL="${KEY_SERVER_URL:-https://keys.netentive.io}"
INSTALL_DIR="$HOME/netentive"

while [[ $# -gt 0 ]]; do
  case $1 in
    --key) LICENSE_KEY="$2"; shift 2 ;;
    --key-server) KEY_SERVER_URL="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$LICENSE_KEY" ]]; then
  echo "ERROR: Deployment key required."
  echo "Usage: curl -fsSL https://raw.githubusercontent.com/danmcrae-dev/netentive-deploy/main/deploy-netentive.sh | bash -s -- --key NET-XXXX-XXXX-XXXX"
  echo "Contact support@netentive.io to purchase a deployment key."
  exit 1
fi

# ------------------------------------------------------------------
# Detect platform (mac / linux / wsl)
# ------------------------------------------------------------------
OS_TYPE="$(uname -s)"
case "$OS_TYPE" in
    Darwin) PLATFORM="mac" ;;
    Linux)
        if grep -qi microsoft /proc/version 2>/dev/null; then
            PLATFORM="wsl"
        else
            PLATFORM="linux"
        fi
        ;;
    *) err "Unsupported OS: $OS_TYPE"; exit 1 ;;
esac

REPO_SAAS="git@github.com:danmcrae-dev/netentive-saas.git"
REPO_MCP="git@github.com:danmcrae-dev/netentive-mcp.git"
REPO_CORE="git@github.com:danmcrae-dev/netentive-core.git"
SAAS_PORT=8000
MCP_PORT=8443

# Colima VM sizing — adjustable via env vars (macOS only)
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

# Platform-aware banner
case "$PLATFORM" in
    mac)
        BANNER_POWERED="Powered by Colima (no Docker Desktop required)"
        ;;
    linux)
        BANNER_POWERED="Powered by Docker CE (native Linux)"
        ;;
    wsl)
        BANNER_POWERED="Powered by Docker Desktop (WSL2 backend)"
        ;;
esac

# Build the banner with proper padding (box interior = 63 chars between | borders)
BANNER_LINE2="        ${BANNER_POWERED}"
BANNER_PAD2=$(( 63 - ${#BANNER_LINE2} ))
printf -v BANNER_PAD2_STR '%*s' "$BANNER_PAD2" ''
BANNER_LINE2="${BANNER_LINE2}${BANNER_PAD2_STR}"

cat << BANNER
+---------------------------------------------------------------+
|         Netentive Platform - One-Command Deploy                |
|        SaaS + MCP + Agent + PostgreSQL + Redis                 |
|${BANNER_LINE2}|
+---------------------------------------------------------------+
BANNER

echo "  Install directory: ${INSTALL_DIR}"
echo "  SaaS port:          ${SAAS_PORT}"
echo "  MCP port:           ${MCP_PORT}"
if [[ "$PLATFORM" == "mac" ]]; then
    echo "  Colima VM:          ${COLIMA_CPU} CPU, ${COLIMA_MEMORY}GB RAM, ${COLIMA_DISK}GB disk"
fi
echo "  Platform:           $(uname -s) $(uname -m) [${PLATFORM}]"
echo ""

# ==================================================================
# Steps 1-3: Install prerequisites + Docker + start runtime
# (platform-specific)
# ==================================================================

if [[ "$PLATFORM" == "mac" ]]; then

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

# Ensure `docker compose` (v2 plugin) is available — Homebrew installs the
# plugin to a Cellar path that isn't always on Docker's cli-plugins search list.
if ! docker compose version &>/dev/null; then
    info "Linking docker-compose plugin..."
    mkdir -p "$HOME/.docker/cli-plugins"
    COMPOSE_PLUGIN=$(find /opt/homebrew/Cellar/docker-compose/*/lib/docker/cli-plugins/docker-compose 2>/dev/null | head -1)
    if [[ -n "$COMPOSE_PLUGIN" ]]; then
        ln -sf "$COMPOSE_PLUGIN" "$HOME/.docker/cli-plugins/docker-compose"
        ok "docker compose plugin linked"
    else
        warn "Could not find docker-compose plugin — falling back to docker-compose"
    fi
fi
ok "Compose: $(docker compose version 2>/dev/null || docker-compose --version 2>/dev/null | head -1)"

# ==================================================================
# Step 3: Start Colima VM with host networking
# ==================================================================
title "Step 3: Starting Colima VM"

# Check if Colima is already running
if colima status 2>/dev/null | grep -q "Running"; then
    ok "Colima is already running"
    # Check if host networking is enabled
    if ! docker info 2>/dev/null | grep -q "host"; then
        warn "Colima running but host networking may not be enabled — restarting"
        colima stop
        colima start --cpu "${COLIMA_CPU}" --memory "${COLIMA_MEMORY}" --disk "${COLIMA_DISK}" --network-address --dns 8.8.8.8
    fi
else
    info "Starting Colima VM (${COLIMA_CPU} CPU, ${COLIMA_MEMORY}GB RAM, ${COLIMA_DISK}GB disk)..."
    info "This takes 30-60 seconds on first run..."
    colima start --cpu "${COLIMA_CPU}" --memory "${COLIMA_MEMORY}" --disk "${COLIMA_DISK}" --network-address --dns 8.8.8.8
fi

# Quick DNS connectivity test — try to pull a tiny image.
# If this fails, restart Colima with explicit DNS (fixes IPv6 Docker Hub issues).
info "Testing Docker Hub connectivity..."
if ! docker pull hello-world 2>/dev/null; then
    warn "Docker Hub pull failed — restarting Colima with explicit DNS (8.8.8.8)..."
    colima stop
    colima start --cpu "${COLIMA_CPU}" --memory "${COLIMA_MEMORY}" --disk "${COLIMA_DISK}" --network-address --dns 8.8.8.8
    if ! docker pull hello-world 2>/dev/null; then
        err "Cannot pull images from Docker Hub. Check your internet connection."
        err "If you're behind a VPN or firewall, try: colima start --network-address --dns 1.1.1.1"
        exit 1
    fi
fi
ok "Docker Hub connectivity verified (docker pull)"

# Disable IPv6 inside Colima VM — Docker BuildKit prefers IPv6 for auth.docker.io
# which fails on some Mac networks. Forcing IPv4 fixes "socket is not connected" errors.
# IMPORTANT: redirect stdin from /dev/null — colima ssh reads stdin and would
# consume the rest of the piped script, killing it silently.
info "Disabling IPv6 in Colima VM (fixes Docker BuildKit auth failures)..."
set +e
colima ssh < /dev/null -- sudo sh -c 'sysctl -w net.ipv6.conf.all.disable_ipv6=1; sysctl -w net.ipv6.conf.default.disable_ipv6=1' 2>/dev/null
set -e
ok "IPv6 disabled in Colima VM"

# Add routes so containers can reach private network hosts (MCP agent SSH,
# remote Ollama servers, network devices on any subnet).
# Colima VMs use NAT networking (192.168.5.x / 192.168.64.x) and can't
# route to private LANs by default. We add routes for ALL private network
# ranges via the Mac host gateway on the col0 interface — the Mac can
# reach any network it has a route to, so this covers multi-subnet setups.
set +e
COLIMA_GATEWAY=$(colima ssh < /dev/null -- ip route show default 2>/dev/null | grep col0 | awk '{print $3}' | head -1)
if [ -n "$COLIMA_GATEWAY" ]; then
    info "Adding Colima VM routes to all private networks via $COLIMA_GATEWAY..."
    for CIDR in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
        colima ssh < /dev/null -- sudo ip route add "$CIDR" via "$COLIMA_GATEWAY" dev col0 2>/dev/null
    done
    ok "Colima VM can now reach all private network hosts (10.x, 172.16-31.x, 192.168.x)"
fi
set -e

# Pre-pull all base images that docker build will need.
# docker pull works (uses daemon networking) but docker build's BuildKit
# can fail fetching auth.docker.io tokens even with IPv6 disabled (cached state).
# If all base images are in the local cache, BuildKit won't need to contact
# the registry at all — the build succeeds from cache.
info "Pre-pulling base images (avoids BuildKit registry auth issues)..."
BASE_IMAGES="python:3.11-slim node:20-slim node:20-alpine nginx:alpine"
for img in $BASE_IMAGES; do
    info "  Pulling $img..."
    if docker pull "$img" 2>/dev/null; then
        ok "  $img ready"
    else
        warn "  Failed to pull $img — build may fail. Will retry during build."
    fi
done
ok "Base images pre-pulled"

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

elif [[ "$PLATFORM" == "linux" ]]; then

# ==================================================================
# Step 1: Check package manager
# ==================================================================
title "Step 1: Checking package manager"

PKG_MGR=""
if command -v apt-get &>/dev/null; then
    PKG_MGR="apt-get"
    ok "apt-get found"
elif command -v dnf &>/dev/null; then
    warn "dnf detected — automated Docker CE install not yet supported for RHEL/Fedora."
    warn "Please install Docker CE manually, then re-run this script."
    warn "See: https://docs.docker.com/engine/install/fedora/"
    exit 1
elif command -v yum &>/dev/null; then
    warn "yum detected — automated Docker CE install not yet supported for CentOS/RHEL."
    warn "Please install Docker CE manually, then re-run this script."
    warn "See: https://docs.docker.com/engine/install/centos/"
    exit 1
else
    err "No supported package manager found (apt-get/dnf/yum)."
    err "Please install Docker CE manually, then re-run this script."
    exit 1
fi

# ==================================================================
# Step 2: Install Docker CE + docker-compose-plugin + git via apt-get
# ==================================================================
title "Step 2: Installing Docker CE"

# Check if Docker CE + compose plugin are already installed.
# If so, skip the entire apt-get installation block to avoid spurious sudo
# password prompts on machines where Docker is already present.
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    ok "Docker CE already installed: $(docker --version)"
    ok "Compose: $(docker compose version 2>/dev/null | head -1)"
else

info "Installing prerequisite packages..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

info "Adding Docker's official GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

info "Adding Docker repository..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
info "Installing docker-ce, docker-compose-plugin, and git..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin git
ok "Docker CE installed"

# Add current user to docker group (avoids needing sudo for docker commands)
info "Adding user '$USER' to docker group..."
sudo usermod -aG docker "$USER"
warn "You may need to log out and back in for the docker group change to take effect."
warn "For now, this script will use sudo where needed."

# Verify docker CLI is available
if ! command -v docker &>/dev/null; then
    err "docker CLI not found after install. Check your PATH."
    exit 1
fi
ok "Docker CLI: $(docker --version)"

# Verify docker compose plugin
if ! docker compose version &>/dev/null; then
    err "docker compose plugin not found. Install docker-compose-plugin."
    exit 1
fi
ok "Compose: $(docker compose version 2>/dev/null | head -1)"

fi # end Docker-already-installed check

# ==================================================================
# Step 3: Start Docker service
# ==================================================================
title "Step 3: Starting Docker service"

if systemctl is-active --quiet docker; then
    ok "Docker service is already running"
else
    info "Starting Docker service..."
    sudo systemctl start docker
    ok "Docker service started"
fi

# Pre-pull base images (shared)
info "Pre-pulling base images..."
BASE_IMAGES="python:3.11-slim node:20-slim node:20-alpine nginx:alpine"
for img in $BASE_IMAGES; do
    info "  Pulling $img..."
    if docker pull "$img" 2>/dev/null; then
        ok "  $img ready"
    else
        warn "  Failed to pull $img — build may fail. Will retry during build."
    fi
done
ok "Base images pre-pulled"

# Verify Docker daemon is responsive
if ! docker info &>/dev/null; then
    err "Docker daemon is not responding. Try: sudo systemctl start docker"
    exit 1
fi
ok "Docker daemon is running"

# Verify host networking works (our compose files use network_mode: host)
if docker run --rm --network host alpine sh -c "echo host-network-ok" 2>/dev/null | grep -q "host-network-ok"; then
    ok "Host networking is functional"
else
    warn "Host networking test failed — containers may not bind to localhost directly"
fi

elif [[ "$PLATFORM" == "wsl" ]]; then

# ==================================================================
# Step 1: Verify Docker Desktop is installed
# ==================================================================
title "Step 1: Checking Docker Desktop"

if ! command -v docker &>/dev/null; then
    err "Docker not found. Install Docker Desktop for Windows with WSL2 backend:"
    err "  1. Download from https://www.docker.com/products/docker-desktop/"
    err "  2. During install, select \"Use WSL 2 instead of Hyper-V\""
    err "  3. In Docker Desktop settings, ensure WSL2 integration is enabled for your distro"
    err "  4. Restart this script"
    exit 1
fi
ok "Docker CLI found: $(docker --version)"

# ==================================================================
# Step 2: Verify docker compose + daemon
# ==================================================================
title "Step 2: Verifying Docker Desktop"

if ! docker compose version &>/dev/null; then
    err "docker compose not available. Ensure Docker Desktop is running with WSL2 integration enabled."
    err "Check Settings > Resources > WSL Integration in Docker Desktop."
    exit 1
fi
ok "Compose: $(docker compose version 2>/dev/null | head -1)"

if ! docker info &>/dev/null; then
    err "Docker daemon is not responding."
    err "Start Docker Desktop for Windows, then re-run this script."
    exit 1
fi
ok "Docker daemon is running via Docker Desktop"

# ==================================================================
# Step 3: Pre-pull base images + host networking test
# ==================================================================
title "Step 3: Preparing Docker environment"

# Pre-pull base images (shared)
info "Pre-pulling base images..."
BASE_IMAGES="python:3.11-slim node:20-slim node:20-alpine nginx:alpine"
for img in $BASE_IMAGES; do
    info "  Pulling $img..."
    if docker pull "$img" 2>/dev/null; then
        ok "  $img ready"
    else
        warn "  Failed to pull $img — build may fail. Will retry during build."
    fi
done
ok "Base images pre-pulled"

# Verify host networking works (our compose files use network_mode: host)
# WSL2 may handle this differently — Docker Desktop's WSL2 integration
# forwards localhost ports from Windows to the WSL2 VM.
if docker run --rm --network host alpine sh -c "echo host-network-ok" 2>/dev/null | grep -q "host-network-ok"; then
    ok "Host networking is functional"
else
    warn "Host networking not available in WSL2 — containers will bind to WSL2's IP."
    warn "Docker Desktop's WSL2 integration should forward localhost ports to Windows."
    warn "If localhost:8000 doesn't work in your browser, check Docker Desktop settings."
fi

fi # end platform-specific Steps 1-3

# ==================================================================
# Architecture detection (shared)
# ==================================================================
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)  ARCH_LABEL="x86_64"  ;;
    arm64|aarch64) ARCH_LABEL="ARM64"   ;;
    *)             ARCH_LABEL="$ARCH"   ;;
esac
ok "Architecture: ${ARCH_LABEL}"

# ==================================================================
# Step 4: Validate deployment key & obtain SSH deploy key
# ==================================================================
title "Step 4: Validating deployment key"

info "Contacting key server: ${KEY_SERVER_URL}"
info "Hostname: $(hostname)"

DEPLOY_KEY_FILE=""
DEPLOY_KEY_BASE64=""

# Build JSON body safely — use python3 if available, otherwise use printf
# (key format is validated server-side so injection risk is minimal)
if command -v python3 &>/dev/null; then
    JSON_BODY=$(python3 -c "import json,sys,socket; print(json.dumps({'key': sys.argv[1], 'hostname': socket.gethostname()}))" "$LICENSE_KEY" 2>/dev/null)
else
    # Fallback: build JSON manually (key is validated server-side with regex)
    JSON_BODY="{\"key\": \"${LICENSE_KEY}\", \"hostname\": \"$(hostname)\"}"
fi

# Use -s (silent progress) but NOT -f (don't fail on HTTP error codes)
# We want to see the actual JSON response even if the server returns an error code
RESPONSE=$(curl -s -X POST "${KEY_SERVER_URL}/v1/deploy-key/redeem" \
  -H "Content-Type: application/json" \
  -d "$JSON_BODY" --connect-timeout 10 2>&1)

if [[ -z "$RESPONSE" ]]; then
    err "Failed to contact key server at ${KEY_SERVER_URL}"
    err "No response received. Check your network connection."
    exit 1
fi

# Parse JSON response using grep/sed (no python3 dependency)
# Response format: {"valid": true, ...} or {"valid": false, "reason": "invalid", ...}
KEY_VALID=$(echo "$RESPONSE" | grep -o '"valid"[[:space:]]*:[[:space:]]*true' | head -1)

if [[ -z "$KEY_VALID" ]]; then
    # Extract reason field — match "reason": "value"
    KEY_REASON=$(echo "$RESPONSE" | grep -o '"reason"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:.*"\([^"]*\)"/\1/' | head -1)
    KEY_REASON="${KEY_REASON:-unknown}"
    err "Deployment key validation failed."
    err "Reason: ${KEY_REASON}"
    case "$KEY_REASON" in
        invalid)   err "The key is not recognized. Check for typos." ;;
        expired)   err "The key has expired. Contact support@netentive.io to renew." ;;
        revoked)   err "The key has been revoked. Contact support@netentive.io." ;;
        max_installs) err "The key has reached its maximum number of installations." ;;
        *)         err "Unexpected response from key server." ;;
    esac
    exit 1
fi

ok "Deployment key is valid"

# Extract per-repo SSH deploy keys from the response
# Response format: {"deploy_keys": {"netentive-saas": "base64...", ...}}
# We extract each key with grep/sed (no python3 dependency)
DEPLOY_KEY_DIR=$(mktemp -d)

extract_repo_key() {
    local repo="$1"
    # Match "repo": "base64value" in the JSON response
    local b64val
    b64val=$(echo "$RESPONSE" | grep -o "\"${repo}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed "s/.*:.*\"\([^\"]*\)\"/\1/" | head -1)
    if [[ -n "$b64val" ]]; then
        echo "$b64val" | base64 -d > "$DEPLOY_KEY_DIR/${repo}.key"
        chmod 600 "$DEPLOY_KEY_DIR/${repo}.key"
    fi
}

extract_repo_key "netentive-saas"
extract_repo_key "netentive-mcp"
extract_repo_key "netentive-core"

# Verify we got keys for all 3 repos
for repo in netentive-saas netentive-mcp netentive-core; do
    if [[ ! -f "$DEPLOY_KEY_DIR/${repo}.key" ]]; then
        err "Key server did not return a deploy key for ${repo}."
        rm -rf "$DEPLOY_KEY_DIR"
        exit 1
    fi
done

# Pin GitHub's SSH host key to prevent MITM attacks
KNOWN_HOSTS_FILE=$(mktemp)
ssh-keyscan -t ed25519 github.com >> "$KNOWN_HOSTS_FILE" 2>/dev/null

# Guarantee cleanup of deploy keys and known_hosts on any exit
cleanup_deploy_keys() {
    if [[ -n "$DEPLOY_KEY_DIR" && -d "$DEPLOY_KEY_DIR" ]]; then
        rm -rf "$DEPLOY_KEY_DIR"
    fi
    if [[ -n "$KNOWN_HOSTS_FILE" && -f "$KNOWN_HOSTS_FILE" ]]; then
        rm -f "$KNOWN_HOSTS_FILE"
    fi
    unset GIT_SSH_COMMAND
}
trap cleanup_deploy_keys EXIT INT TERM ERR

ok "SSH deploy keys installed (${DEPLOY_KEY_DIR})"

# Show expiry if present (extract with grep/sed — no python3 dependency)
KEY_EXPIRES=$(echo "$RESPONSE" | grep -o '"expires_at"[[:space:]]*:[[:space:]]*null' | head -1)
if [[ "$KEY_EXPIRES" == *null* ]]; then
    KEY_EXPIRES="never"
else
    KEY_EXPIRES=$(echo "$RESPONSE" | grep -o '"expires_at"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:.*"\([^"]*\)"/\1/' | head -1)
    KEY_EXPIRES="${KEY_EXPIRES:-n/a}"
fi
info "Key expires: ${KEY_EXPIRES}"

# ==================================================================
# Step 5: Clone repos
# ==================================================================
title "Step 5: Cloning repositories"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

clone_repo() {
    local name="$1" url="$2"
    local key_file="$DEPLOY_KEY_DIR/${name}.key"
    export GIT_SSH_COMMAND="ssh -i ${key_file} -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS_FILE"
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

# Remove the deploy keys now that cloning is done
rm -rf "$DEPLOY_KEY_DIR"
rm -f "$KNOWN_HOSTS_FILE"
unset GIT_SSH_COMMAND
trap - EXIT INT TERM ERR
DEPLOY_KEY_DIR=""
KNOWN_HOSTS_FILE=""
ok "SSH deploy keys removed from disk"

# ==================================================================
# Step 6: Generate secrets
# ==================================================================
title "Step 6: Generating configuration"

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
SECRET_KEY="$(generate_password)"
ADMIN_PASSWORD="$(openssl rand -base64 12 2>/dev/null | tr -d '/+=' | cut -c1-16 || python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(16)))')"

info "Generated DB_PASSWORD (${#DB_PASSWORD} chars)"
info "Generated MCP_API_KEY (${#MCP_API_KEY} chars)"
info "Generated VAULT_KEY (${#VAULT_KEY} chars)"
info "Generated ADMIN_PASSWORD (${#ADMIN_PASSWORD} chars)"

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
# Step 7: Write .env files
# ==================================================================
title "Step 7: Writing configuration"

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
    echo ""
    echo "# Auth / JWT"
    echo "SECRET_KEY=${SECRET_KEY}"
    echo "ACCESS_TOKEN_EXPIRE_MINUTES=1440"
    echo "ALGORITHM=HS256"
    echo ""
    echo "# PHP Bridge (empty = standalone local auth, no external PHP site)"
    echo "PHP_BRIDGE_SECRET="
    echo "PHP_SITE_URL=https://netentive.ai"
    echo "MCP_SERVICE_EMAIL=service@netentive.ai"
    echo "MCP_SERVICE_PASSWORD=${MCP_SERVICE_PASSWORD}"
    echo ""
    echo "# Credential Vault"
    echo "VAULT_ENCRYPTION_KEY=${VAULT_KEY}"
    echo ""
    echo "# MCP Connection"
    echo "MCP_API_KEY=${MCP_API_KEY}"
    echo "MCP_SERVER_URL=http://localhost:${MCP_PORT}"
    echo "MCP_AGENT_ID=agent-01"
    echo ""
    echo "# Frontend"
    echo "FRONTEND_URL=http://localhost:${SAAS_PORT}"
    echo ""
    echo "# Default admin (seed_admin.py reads these on first boot)"
    echo "ADMIN_EMAIL=admin@netentive.local"
    echo "ADMIN_PASSWORD=${ADMIN_PASSWORD}"
} > "$SAAS_ENV"
chmod 600 "$SAAS_ENV"
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
chmod 600 "$MCP_ENV"
ok "MCP .env written"

# ==================================================================
# Step 8: Build and start SaaS
# ==================================================================
title "Step 8: Building and starting SaaS"

# Colima supports network_mode: host, so we use the original compose files
# directly — no patching needed.

info "Building SaaS images (this takes 3-8 minutes on first run)..."
cd "$INSTALL_DIR/netentive-saas/deployment"

# Source the .env file so docker-compose can resolve ${VARS} on the host side.
# docker-compose resolves ${} from shell env, not from env_file directive.
# env_file loads vars INTO the container, but host-side substitution needs them in the shell.
set -a
source "$INSTALL_DIR/netentive-saas/.env"
set +a

docker compose up -d --build 2>&1 | tail -20

ok "SaaS containers started"

# Wait for postgres, then run migrations
info "Waiting for PostgreSQL..."
PG_READY=false
for i in $(seq 1 30); do
    if docker compose exec -T postgres pg_isready -U netentive 2>/dev/null; then
        ok "PostgreSQL is ready"
        PG_READY=true
        break
    fi
    info "  Waiting... ($i/30)"
    sleep 3
done

if [[ "$PG_READY" != "true" ]]; then
    err "PostgreSQL did not become ready in 90 seconds."
    err "Checking container status..."
    docker compose ps
    err "Postgres logs (last 20 lines):"
    docker compose logs --tail 20 postgres 2>&1
    exit 1
fi

info "Running database migrations..."
set +e
docker compose exec -T api python -m alembic upgrade head 2>&1
MIGRATE_EXIT=$?
set -e
if [[ $MIGRATE_EXIT -ne 0 ]]; then
    err "Database migrations failed (exit code $MIGRATE_EXIT)."
    err "SaaS API logs (last 20 lines):"
    docker compose logs --tail 20 api 2>&1
    exit 1
fi
ok "Database migrations complete"

# ==================================================================
# Step 8b: Seed default admin user
# ==================================================================
info "Seeding default admin user..."

# Ensure ADMIN_EMAIL / ADMIN_PASSWORD are present in the container env.
# The .env file already contains them (written in Step 7), and
# `set -a; source .env` above exports them into the shell, so
# `docker compose exec` inherits them.  Run the seeder and capture output.
SEED_OUTPUT=""
set +e
SEED_OUTPUT="$(docker compose exec -T api python /app/backend/seed_admin.py 2>&1)"
SEED_EXIT=$?
set -e
echo "$SEED_OUTPUT"
if [[ $SEED_EXIT -ne 0 ]]; then
    err "Admin seed failed (exit code $SEED_EXIT)."
    err "SaaS API logs (last 20 lines):"
    docker compose logs --tail 20 api 2>&1
    exit 1
fi

# Parse credentials from seeder output (ADMIN_EMAIL=... / ADMIN_PASSWORD=...)
SEED_ADMIN_EMAIL="$(echo "$SEED_OUTPUT" | grep -m1 '^ADMIN_EMAIL=' | cut -d= -f2-)"
SEED_ADMIN_PASSWORD="$(echo "$SEED_OUTPUT" | grep -m1 '^ADMIN_PASSWORD=' | cut -d= -f2-)"
# Fall back to .env values if seeder didn't print them (e.g. users already existed)
SEED_ADMIN_EMAIL="${SEED_ADMIN_EMAIL:-$ADMIN_EMAIL}"
SEED_ADMIN_PASSWORD="${SEED_ADMIN_PASSWORD:-$ADMIN_PASSWORD}"
ok "Admin seed complete"

# ==================================================================
# Step 9: Build and start MCP
# ==================================================================
title "Step 9: Building and starting MCP"

mkdir -p "$INSTALL_DIR/netentive-mcp/data" 2>/dev/null || true
mkdir -p "$HOME/.ssh/netentive_agents" 2>/dev/null || true

info "Building MCP images (this takes 2-5 minutes)..."
cd "$INSTALL_DIR/netentive-mcp"

# Source the MCP .env file so docker-compose can resolve ${VARS} on the host side.
set -a
source "$INSTALL_DIR/netentive-mcp/.env"
set +a

docker compose up -d --build 2>&1 | tail -20

ok "MCP containers started"

# ==================================================================
# Step 10: Health checks
# ==================================================================
title "Step 10: Health checks"

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
# Step 11: Install auto-start on login (platform-specific)
# ==================================================================
title "Step 11: Installing auto-start on login"

# Clone the deploy repo if not present (needed for scripts/ templates)
DEPLOY_REPO_DIR="$INSTALL_DIR/netentive-deploy"
DEPLOY_SCRIPTS_DIR="$DEPLOY_REPO_DIR/scripts"

if [[ ! -d "$DEPLOY_SCRIPTS_DIR" ]]; then
    info "Cloning deploy repo for auto-start templates..."
    git clone --depth 1 https://github.com/danmcrae-dev/netentive-deploy.git "$DEPLOY_REPO_DIR" 2>/dev/null || true
fi

if [[ ! -f "$DEPLOY_SCRIPTS_DIR/netentive-start.sh" ]]; then
    warn "Startup script template not found, skipping auto-start installation"
else
    info "Copying startup script to ${INSTALL_DIR}/netentive-start.sh"
    cp "$DEPLOY_SCRIPTS_DIR/netentive-start.sh" "$INSTALL_DIR/netentive-start.sh"
    chmod +x "$INSTALL_DIR/netentive-start.sh"
    ok "Startup script installed"

    if [[ "$PLATFORM" == "mac" ]]; then
        # macOS: launchd plist installation
        if [[ -f "$DEPLOY_SCRIPTS_DIR/com.netentive.startup.plist" ]]; then
            info "Installing launchd agent..."
            mkdir -p "$HOME/Library/LaunchAgents"
            sed "s|__HOME__|${HOME}|g" "$DEPLOY_SCRIPTS_DIR/com.netentive.startup.plist" \
                > "$HOME/Library/LaunchAgents/com.netentive.startup.plist"
            launchctl load "$HOME/Library/LaunchAgents/com.netentive.startup.plist" 2>/dev/null || true
            ok "Auto-start installed — Netentive will start automatically on login"
        else
            warn "launchd plist template not found, skipping auto-start installation"
        fi

    elif [[ "$PLATFORM" == "linux" ]]; then
        # Linux: systemd user service
        if [[ -f "$DEPLOY_SCRIPTS_DIR/netentive.service" ]]; then
            info "Installing systemd user service..."
            mkdir -p "$HOME/.config/systemd/user"
            sed "s|__HOME__|${HOME}|" "$DEPLOY_SCRIPTS_DIR/netentive.service" \
                > "$HOME/.config/systemd/user/netentive.service"
            systemctl --user enable netentive.service 2>/dev/null || true
            systemctl --user daemon-reload 2>/dev/null || true
            ok "Auto-start installed — Netentive will start on login via systemd"
            info "Note: You may need to run 'loginctl enable-linger $USER' for auto-start without an active session."
        else
            warn "systemd service template not found, skipping auto-start installation"
        fi

    elif [[ "$PLATFORM" == "wsl" ]]; then
        # WSL2: Windows Task Scheduler via PowerShell
        if [[ -f "$DEPLOY_SCRIPTS_DIR/install-windows-autostart.ps1" ]]; then
            info "To install auto-start on Windows, run this in PowerShell:"
            info "  wsl -e bash -c 'cat ~/netentive/netentive-deploy/scripts/install-windows-autostart.ps1' | powershell.exe -"
            ok "PowerShell auto-start script available at ${DEPLOY_SCRIPTS_DIR}/install-windows-autostart.ps1"
        else
            warn "PowerShell auto-start template not found, skipping"
        fi
    fi
fi

# ==================================================================
# Step 12: Show status + summary (platform-adaptive)
# ==================================================================
title "Step 12: Deployment status"

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
echo "    2. Log in with the admin credentials below"
echo "    3. Add your managed devices in the Devices page"
echo "    4. Credentials are synced to the MCP agent automatically"
echo ""
echo "  +---------------------------------------------------------------+"
echo "  |  ${BOLD}Default admin credentials (CHANGE IMMEDIATELY!)${NC}        |"
echo "  +---------------------------------------------------------------+"
echo "  |  Email:    ${SEED_ADMIN_EMAIL}"
echo "  |  Password: ${SEED_ADMIN_PASSWORD}"
echo "  +---------------------------------------------------------------+"
echo ""
warn "Change the admin password immediately after first login!"
echo ""
echo "  To stop:"
echo "    cd ${INSTALL_DIR}/netentive-saas/deployment && docker compose down"
echo "    cd ${INSTALL_DIR}/netentive-mcp && docker compose down"

if [[ "$PLATFORM" == "mac" ]]; then
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

elif [[ "$PLATFORM" == "linux" ]]; then
    echo "    sudo systemctl stop docker"
    echo ""
    echo "  To restart:"
    echo "    sudo systemctl start docker"
    echo "    cd ${INSTALL_DIR}/netentive-saas/deployment && docker compose up -d"
    echo "    cd ${INSTALL_DIR}/netentive-mcp && docker compose up -d"
    echo ""
    echo "  To update (pull latest + rebuild):"
    echo "    cd ${INSTALL_DIR}/netentive-saas && git pull && cd deployment && docker compose up -d --build"
    echo "    cd ${INSTALL_DIR}/netentive-mcp && git pull && docker compose up -d --build"
    echo ""
    echo "  Docker service management:"
    echo "    sudo systemctl status docker   - check service status"
    echo "    sudo systemctl stop docker     - stop Docker (frees RAM)"
    echo "    sudo systemctl start docker    - start Docker"
    echo "    sudo systemctl restart docker  - restart Docker"

elif [[ "$PLATFORM" == "wsl" ]]; then
    echo "    Close Docker Desktop"
    echo ""
    echo "  To restart:"
    echo "    Start Docker Desktop"
    echo "    cd ${INSTALL_DIR}/netentive-saas/deployment && docker compose up -d"
    echo "    cd ${INSTALL_DIR}/netentive-mcp && docker compose up -d"
    echo ""
    echo "  To update (pull latest + rebuild):"
    echo "    cd ${INSTALL_DIR}/netentive-saas && git pull && cd deployment && docker compose up -d --build"
    echo "    cd ${INSTALL_DIR}/netentive-mcp && git pull && docker compose up -d --build"
    echo ""
    echo "  Docker Desktop management:"
    echo "    Start Docker Desktop from Windows Start menu"
    echo "    Check Settings > Resources > WSL Integration is enabled"
fi

echo ""