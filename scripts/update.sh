#!/usr/bin/env bash
set -euo pipefail

# ==================================================================
# Netentive Update Script
#
# Pulls latest code for all repos and rebuilds Docker containers.
# Called by the in-app System → Update button, or run manually.
#
# Usage:
#   ./update.sh [INSTALL_DIR]
#
# Default install dir: ~/netentive
# ==================================================================

INSTALL_DIR="${1:-$HOME/netentive}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

echo ""
echo "  Netentive Update"
echo "  Install directory: ${INSTALL_DIR}"
echo ""

# ── Pull latest code ──────────────────────────────────────────────
info "Pulling latest code for all repos..."

for repo in netentive-saas netentive-mcp netentive-core; do
    if [ -d "$INSTALL_DIR/$repo" ]; then
        info "  $repo..."
        (cd "$INSTALL_DIR/$repo" && git pull --ff-only) || err "  $repo pull failed"
        ok "  $repo updated"
    fi
done

# ── Rebuild SaaS ──────────────────────────────────────────────────
info "Rebuilding SaaS containers..."
cd "$INSTALL_DIR/netentive-saas/deployment"
docker compose up -d --build 2>&1 | tail -5
ok "SaaS rebuilt"

# Run migrations
info "Running database migrations..."
docker compose exec -T api python -m alembic upgrade head 2>&1 | tail -3
ok "Migrations complete"

# ── Rebuild MCP ───────────────────────────────────────────────────
info "Rebuilding MCP containers..."
cd "$INSTALL_DIR/netentive-mcp"
docker compose up -d --build 2>&1 | tail -5
ok "MCP rebuilt"

# ── Health check ──────────────────────────────────────────────────
info "Health checks..."
sleep 3

if curl -sf --max-time 10 http://localhost:8000/api/v1/status >/dev/null 2>&1; then
    ok "SaaS is healthy"
else
    err "SaaS health check failed"
fi

if curl -sf --max-time 10 http://localhost:8443/health >/dev/null 2>&1; then
    ok "MCP is healthy"
else
    err "MCP health check failed"
fi

echo ""
ok "Update complete!"
echo ""