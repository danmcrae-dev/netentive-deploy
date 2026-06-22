# netentive-deploy

One-command deployment for the Netentive network assessment platform.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/danmcrae-dev/netentive-deploy/main/deploy-netentive.sh | bash -s -- --key NET-XXXX-XXXX-XXXX
```

You need a deployment key. Contact support@netentive.io to purchase one.

## Prerequisites

- **macOS 12+** (Monterey or later)
- **8 GB RAM minimum** (16 GB recommended)
- **50 GB free disk space**
- **Internet connection** (for cloning repos and downloading Docker images)

The script auto-installs:
- Homebrew (if missing)
- Colima (Docker daemon for macOS — no Docker Desktop required)
- Docker CLI + Docker Compose
- Git

## What It Does

1. Installs prerequisites (Homebrew, Colima, Docker, Git)
2. Validates your deployment key against the Netentive key server
3. Clones the three private repos (netentive-saas, netentive-mcp, netentive-core)
4. Generates fresh secrets (DB password, API keys, Fernet vault key)
5. Builds and starts all Docker containers
6. Runs database migrations
7. Health checks all services
8. Prints the dashboard URL and management commands

## Usage

### Install

```bash
curl -fsSL https://raw.githubusercontent.com/danmcrae-dev/netentive-deploy/main/deploy-netentive.sh | bash -s -- --key NET-XXXX-XXXX-XXXX
```

Or clone and run locally:

```bash
git clone https://github.com/danmcrae-dev/netentive-deploy.git
cd netentive-deploy
./deploy-netentive.sh --key NET-XXXX-XXXX-XXXX
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--key` | **Required.** Deployment license key | — |
| `--key-server` | Key validation server URL | `https://keys.netentive.io` |
| `--install-dir` | Directory to clone repos into | `~/netentive` |

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `KEY_SERVER_URL` | Key validation server URL | `https://keys.netentive.io` |
| `COLIMA_CPU` | Colima VM CPU cores | `4` |
| `COLIMA_MEMORY` | Colima VM RAM (GB) | `6` |
| `COLIMA_DISK` | Colima VM disk (GB) | `50` |

## After Installation

The platform runs at **http://localhost:8000**

Management commands:

```bash
# View running containers
docker ps

# Stop all services
cd ~/netentive/netentive-saas/deployment && docker compose down
cd ~/netentive/netentive-mcp && docker compose down

# Start all services
cd ~/netentive/netentive-saas/deployment && docker compose up -d
cd ~/netentive/netentive-mcp && docker compose up -d

# Update to latest version
cd ~/netentive/netentive-deploy && bash scripts/update.sh
```

## Key Server Setup (For Administrators)

If you're managing license keys for customers, see [`key-server/README.md`](key-server/README.md) for setup instructions.

### Generate a key for a customer

```bash
# On the key server (maximus):
cd ~/netentive-deploy/key-server
python3 keymgr.py create --email customer@company.com --expires 2026-12-31 --max-installs 3
# Output: NET-A3F2-9B1C-4D8E
```

### Revoke a key

```bash
python3 keymgr.py revoke NET-A3F2-9B1C-4D8E
```

### List all keys

```bash
python3 keymgr.py list
```

## Documentation

- [macOS Setup Guide](docs/mac-setup.md)
- [Linux Setup Guide](docs/linux-setup.md)
- [Architecture Overview](docs/architecture.md)
- [Key Server Setup](key-server/README.md)

## License

Proprietary. All rights reserved. Deployment requires a valid license key.