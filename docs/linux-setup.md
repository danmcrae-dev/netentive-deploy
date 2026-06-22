# Linux Setup Guide

## Prerequisites

- Docker 20+ installed
- docker-compose v2+ installed
- Git
- 4GB+ RAM

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/danmcrae-dev/netentive-deploy/main/deploy-netentive.sh | bash
```

On Linux, the script detects that Docker is already installed and skips the Homebrew/Colima steps. It uses the original Docker Compose files directly with `network_mode: host` (native Linux supports this).

## Server Deployment (e.g., Maximus)

For a dedicated server deployment:

```bash
# Clone the deploy repo
git clone git@github.com:danmcrae-dev/netentive-deploy.git
cd netentive-deploy

# Run with default settings
./deploy-netentive.sh /opt/netentive

# Or specify a custom install directory
./deploy-netentive.sh /home/deploy/netentive
```

## Network Configuration

The SaaS and MCP containers use `network_mode: host`, binding directly to the host's network interfaces. Ensure:

- Port 8000 (SaaS) and 8443 (MCP) are available
- Firewall allows access from client machines
- Network devices are reachable from the server (direct or via routing)

## systemd Service (optional)

To auto-start Netentive on boot:

```bash
cat > /etc/systemd/system/netentive.service << 'EOF'
[Unit]
Description=Netentive Platform
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/netentive/netentive-saas/deployment
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
ExecStopPost=/usr/bin/docker compose -f /opt/netentive/netentive-mcp/docker-compose.yml down

[Install]
WantedBy=multi-user.target
EOF

systemctl enable netentive
systemctl start netentive
```

## Backup

The PostgreSQL data volume contains all assessment data, device configs, and user accounts:

```bash
# Backup
docker exec deployment-postgres-1 pg_dump -U netentive netentive > backup.sql

# Restore
docker exec -i deployment-postgres-1 psql -U netentive netentive < backup.sql
```