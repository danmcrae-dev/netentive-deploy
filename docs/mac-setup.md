# macOS Setup Guide

## Prerequisites

- macOS 12+ (Monterey or later)
- 8GB RAM minimum (16GB recommended)
- 20GB free disk space
- VPN connected (if reaching remote network devices)

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/danmcrae-dev/netentive-deploy/main/deploy-netentive.sh | bash
```

The script installs everything:
- Homebrew (if missing)
- Colima (Docker daemon for macOS)
- Docker CLI + docker-compose
- Git
- All three Netentive repos
- Full Docker stack with generated secrets

## Colima vs Docker Desktop

This deployment uses [Colima](https://github.com/abiosoft/colima) instead of Docker Desktop.

| Feature | Docker Desktop | Colima |
|---|---|---|
| Cost | Free <250 employees | Free (Apache 2.0) |
| RAM overhead | 2-4GB (VM + GUI) | 1-2GB (VM only) |
| Host networking | Not supported on Mac | Supported via `--network-address` |
| GUI | Yes | No (CLI only) |
| Apple Silicon | Yes | Yes |

**Why Colima?** The Netentive Docker Compose files use `network_mode: host`. Docker Desktop for Mac doesn't support host networking — containers can't bind to `localhost` directly. Colima with `--network-address` enables host networking, so the compose files work unchanged.

## VPN Configuration

The MCP agent SSHes directly to network device IPs. If devices are on a remote network:

1. Connect to the VPN (WireGuard, OpenVPN, Cisco AnyConnect, etc.)
2. Verify you can reach the device: `ping 10.50.1.1`
3. Run the deploy script — Docker containers inherit the host's VPN routing

The agent can reach any IP that the Mac host can reach.

## Colima VM Sizing

Adjust the VM allocation before running the script:

```bash
# Mac with 16GB RAM — recommended
COLIMA_CPU=4 COLIMA_MEMORY=6 COLIMA_DISK=50 ./deploy-netentive.sh

# Mac with 32GB RAM — for large deployments
COLIMA_CPU=8 COLIMA_MEMORY=12 COLIMA_DISK=100 ./deploy-netentive.sh

# Mac with 8GB RAM — minimum viable
COLIMA_CPU=2 COLIMA_MEMORY=4 COLIMA_DISK=30 ./deploy-netentive.sh
```

## Common Issues

### Colima won't start

```bash
# Check if another Docker is running
colima list
docker context ls

# Reset Colima
colima delete -f
colima start --cpu 4 --memory 6 --disk 50 --network-address
```

### Cannot reach network devices

```bash
# Verify VPN is connected
ifconfig | grep -A 5 "utun"   # macOS VPN interfaces

# Test from inside a container
docker run --rm --network host alpine ping -c 3 10.50.1.1
```

### "Illegal instruction" error on Intel Mac

If you see illegal instruction errors, the Colima VM architecture may not match. Force the correct architecture:

```bash
colima start --arch x86_64 --cpu 4 --memory 6 --disk 50 --network-address
```

### Port conflicts

If port 8000 or 8443 is already in use:

```bash
# Find what's using the port
lsof -i :8000
lsof -i :8443

# Kill it or change the port in .env files
```