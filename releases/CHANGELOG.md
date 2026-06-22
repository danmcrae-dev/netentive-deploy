# Changelog

All notable changes to the Netentive deployment tooling are documented here.

## [Unreleased]

## [0.1.0] - 2026-06-22

### Added
- One-command deploy script (`deploy-netentive.sh`) for macOS and Linux
- Colima-based Docker deployment for macOS (no Docker Desktop required)
- Host networking support via Colima `--network-address`
- Automatic secret generation (DB password, MCP API key, Fernet vault key)
- Automatic `.env` file generation for SaaS and MCP
- Homebrew auto-installation for macOS
- Colima + Docker CLI auto-installation via Homebrew
- Git repo cloning (saas, mcp, core) with `--depth 1`
- PostgreSQL migration execution via Alembic
- Health checks for SaaS and MCP services
- Colima VM sizing via environment variables (`COLIMA_CPU`, `COLIMA_MEMORY`, `COLIMA_DISK`)
- Update script (`scripts/update.sh`) for pulling latest + rebuilding
- macOS setup guide (`docs/mac-setup.md`)
- Linux setup guide (`docs/linux-setup.md`)
- Architecture documentation (`docs/architecture.md`)