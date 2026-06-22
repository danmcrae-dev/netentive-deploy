# Netentive Architecture

## Overview

Netentive is a network assessment platform consisting of three application repos
and a deployment repo.

```
netentive-deploy/          <-- this repo (deployment scripts + docs)
    |
    |-- clones -->
    |
    +-- netentive-saas/    SaaS: FastAPI + React + PostgreSQL + Redis + Celery
    +-- netentive-mcp/     MCP: MCP server + agent + GUI (device management)
    +-- netentive-core/    Core: shared Python library (analysis, compliance)
```

## Component Details

### SaaS (netentive-saas)

The main web application. Provides:

- **Dashboard** — system health, device status, agent overview
- **Devices** — managed device CRUD, credential profiles, CSV import
- **Terminal** — interactive SSH sessions via xterm.js (proxied through MCP agent)
- **AI Chat** — Claude-powered network analysis chat
- **System Settings** — AI model config, system updates, user management
- **MCP Agents** — agent registration, health monitoring, device sync

**Tech stack:**
- Backend: Python FastAPI, SQLAlchemy, Alembic, Celery
- Frontend: React 18, Vite, xterm.js
- Database: PostgreSQL 15
- Cache: Redis 7
- Auth: JWT (24h expiry), PHP bridge (legacy)

**Docker containers:**
- `postgres` — PostgreSQL 15 Alpine
- `redis` — Redis 7 Alpine
- `api` — FastAPI (4 uvicorn workers)
- `celery_worker` — async task execution
- `celery_beat` — scheduled tasks

### MCP (netentive-mcp)

The Management Control Plane. Provides:

- **MCP Server** — device registry, credential vault, command dispatch, SSE events
- **Agent** — connects to network devices via SSH/Telnet (netmiko/paramiko)
- **GUI** — standalone MCP management interface (optional)

**Tech stack:**
- Server: Python FastAPI, SQLite (persistence), zeroconf (mDNS)
- Agent: Python asyncio, netmiko, paramiko
- Auth: Opaque API tokens (in-memory cache), x-api-key for service-to-service

**Docker containers:**
- `mcp-server` — FastAPI on port 8443
- `agent` — asyncio agent loop (SSE + heartbeat)
- `gui` — standalone React app on port 3000

### Core (netentive-core)

Shared Python library. No server. Used by both SaaS and MCP via volume mount.

- Config parsing (Cisco IOS, Arista, FRR, Juniper)
- Compliance checking (NIST, CIS benchmarks)
- Topology analysis
- Config diffing

## Data Flow

```
Browser (React UI)
    |
    | HTTPS (port 8000)
    v
SaaS FastAPI
    |
    |-- HTTP (x-api-key) --> MCP Server (port 8443)
    |                              |
    |                              |-- SSH/Telnet --> Network Devices
    |                              |       (paramiko/netmiko)
    |                              |
    |                              v
    |                          MCP Agent (SSE + heartbeat)
    |
    |-- PostgreSQL --> assessment data, devices, users
    |-- Redis --> Celery task queue
    |-- Celery --> async analysis jobs
```

## Auth Model

| Path | Auth Method |
|---|---|
| Browser → SaaS | JWT (24h expiry, bcrypt password hash) |
| SaaS → MCP Server | `x-api-key` header (shared secret, hmac.compare_digest) |
| MCP Agent → MCP Server | `x-api-key` header |
| MCP Agent → SaaS | `x-api-key` header |
| MCP Server → SaaS (legacy) | `x-api-key` header |

All service-to-service communication uses the `MCP_API_KEY` shared secret via
the `x-api-key` header. No Bearer tokens or JWTs cross the service boundary.

## Credential Vault

Device credentials (SSH passwords, API keys) are encrypted at rest using
Fernet (AES-256-CBC) with a key generated during deployment. The key is stored
in `VAULT_ENCRYPTION_KEY` in the SaaS `.env` file.

Credentials flow:
1. User enters credentials in SaaS UI → encrypted with Fernet → stored in PostgreSQL
2. On device sync, SaaS decrypts credentials → sends to MCP agent via HTTPS
3. MCP agent stores credentials in local SQLite/JSON → uses for SSH connections
4. Credentials are never logged in plaintext

## Networking

All containers use `network_mode: host`:
- SaaS binds to `0.0.0.0:8000`
- MCP binds to `0.0.0.0:8443`
- PostgreSQL binds to `127.0.0.1:5432`
- Redis binds to `127.0.0.1:6379`

This works natively on Linux. On macOS, Colima's `--network-address` flag
enables host networking inside the Colima VM.