# Netentive Key Server

License key validation server for the Netentive deployment system. Customers receive a license key (e.g. `NET-A3F2-9B1C-4D8E`) when they purchase, then run the deploy script which calls this server to validate the key and retrieve a read-only SSH deploy key for cloning the private repos.

## Architecture

```
Customer deploy script
    │
    ▼
POST /v1/deploy-key/validate  ──►  Key Server (FastAPI)
    │                                  │
    │                                  ├── SQLite (/data/keys.db)
    │                                  │     ├── deploy_keys
    │                                  │     └── key_installs
    │                                  │
    │                                  └── .env (DEPLOY_SSH_KEY_BASE64)
    │
    ▼
Returns SSH private key (base64) + repo list
    │
    ▼
git clone git@github.com:danmcrae-dev/{repo}.git
```

The SSH keypair is generated once during setup. The **public key** is added as a read-only Deploy Key to each of the 3 GitHub repos. The **private key** is stored on the key server (base64-encoded in `.env`) and returned to customers upon successful key validation. The license key gates access — the SSH key is shared and read-only.

## Setup

### 1. Generate the SSH deploy keypair

```bash
cd /home/damcrae/netentive/netentive-deploy/key-server
ssh-keygen -t ed25519 -f deploy_key -N "" -C "netentive-deploy-key"
```

This creates:
- `deploy_key` — private key
- `deploy_key.pub` — public key

### 2. Add the public key to each GitHub repo

Go to each repo's settings and add the public key as a **Deploy Key** (read-only):

- https://github.com/danmcrae-dev/netentive-saas/settings/keys
- https://github.com/danmcrae-dev/netentive-mcp/settings/keys
- https://github.com/danmcrae-dev/netentive-core/settings/keys

Paste the contents of `deploy_key.pub` into each. Allow write access is **not** needed.

### 3. Base64-encode the private key

```bash
base64 -w0 deploy_key > deploy_key.b64
```

### 4. Configure .env

```bash
cp .env.example .env
```

Edit `.env` and set:

```
DEPLOY_SSH_KEY_BASE64=<contents of deploy_key.b64>
DEPLOY_SSH_KEY_PUBLIC=<contents of deploy_key.pub>
```

### 5. Build and start the server

```bash
docker compose up -d --build
```

Or run directly (for development):

```bash
pip install -r requirements.txt
python3 key_server.py
```

The server listens on port **7443**.

### 6. Initialize the database

```bash
DB_PATH=./data/keys.db python3 keymgr.py init
```

### 7. Create license keys

```bash
DB_PATH=./data/keys.db python3 keymgr.py create \
    --email customer@company.com \
    --expires 2026-12-31 \
    --max-installs 3 \
    --notes "Acme Corp - Pro tier"
```

The generated key is printed in green. Send it to the customer.

## Key Management

### List all keys

```bash
DB_PATH=./data/keys.db python3 keymgr.py list
```

### Show key details + install history

```bash
DB_PATH=./data/keys.db python3 keymgr.py info NET-A3F2-9B1C-4D8E
```

### Revoke a key

```bash
DB_PATH=./data/keys.db python3 keymgr.py revoke NET-A3F2-9B1C-4D8E
```

### Delete a key

```bash
DB_PATH=./data/keys.db python3 keymgr.py delete NET-A3F2-9B1C-4D8E
```

## API Reference

### `GET /health`

```json
{"status": "ok"}
```

### `POST /v1/deploy-key/validate`

Request:
```json
{"key": "NET-A3F2-9B1C-4D8E"}
```

Success response (200):
```json
{
    "valid": true,
    "deploy_key": "<base64 SSH private key>",
    "repos": ["netentive-saas", "netentive-mcp", "netentive-core"],
    "github_org": "danmcrae-dev",
    "expires_at": "2026-12-31T23:59:59Z",
    "install_count": 1,
    "max_installs": 3
}
```

Failure response (200):
```json
{"valid": false, "reason": "invalid"}
```

Possible reasons: `invalid`, `expired`, `revoked`, `max_installs`.

Rate limit exceeded (429):
```
Rate limit exceeded
```

### `POST /v1/deploy-key/redeem`

Same as validate, but also accepts a `hostname` field and records the install (IP, hostname, timestamp) in the `key_installs` table.

Request:
```json
{"key": "NET-A3F2-9B1C-4D8E", "hostname": "customer-server-01"}
```

## Deployment

The server runs on maximus (192.168.12.132). Docker Compose is configured with:

- Port `7443:7443`
- Volume `./data:/data` (persistent SQLite database)
- `network_mode: host`
- `restart: unless-stopped`

## Security Notes

- **Rate limiting**: 5 attempts per IP per hour (configurable via `RATE_LIMIT_PER_HOUR`). In-memory with automatic cleanup.
- **Key revocation**: Set `revoked=1` via `keymgr.py revoke`. The key immediately stops validating.
- **Install counting**: Each successful validation increments `install_count`. Once it reaches `max_installs`, the key is exhausted.
- **Deploy key rotation**: If the SSH key is compromised, generate a new keypair, update the public keys in GitHub, update `DEPLOY_SSH_KEY_BASE64` in `.env`, and restart. Existing installs lose `git pull` access until they re-validate.
- **CORS**: Enabled for all origins (`*`). Restrict if needed.
- **HTTPS**: Put behind a reverse proxy (nginx/caddy) with TLS for production.

## Key Format

Keys follow the format `NET-XXXX-XXXX-XXXX` where `X` is uppercase hexadecimal. Generated using `secrets.token_hex(2)` for each 4-char group (cryptographically secure).

## Files

| File | Description |
|------|-------------|
| `key_server.py` | FastAPI application |
| `keymgr.py` | CLI key management tool |
| `Dockerfile` | Container image definition |
| `docker-compose.yml` | Container orchestration |
| `requirements.txt` | Python dependencies |
| `.env.example` | Environment variable template |
| `data/` | SQLite database (mounted volume) |