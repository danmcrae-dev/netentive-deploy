#!/usr/bin/env python3
"""
Netentive Key Validation Server.

FastAPI application that validates deployment license keys against a SQLite
database and returns a base64-encoded SSH deploy key for cloning private repos.

Endpoints:
    GET  /health                   — health check
    POST /v1/deploy-key/validate   — validate a key, return SSH key + repos
    POST /v1/deploy-key/redeem     — validate + record install metadata

Run:
    uvicorn key_server:app --host 0.0.0.0 --port 7443
"""

from __future__ import annotations

import os
import re
import sqlite3
import time
from datetime import datetime, timezone
from typing import Optional

from fastapi import FastAPI, Request, HTTPException
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DB_PATH = os.environ.get("DB_PATH", "/data/keys.db")
RATE_LIMIT_PER_HOUR = int(os.environ.get("RATE_LIMIT_PER_HOUR", "5"))
DEPLOY_SSH_KEY_BASE64 = os.environ.get("DEPLOY_SSH_KEY_BASE64", "")

# Per-repo SSH deploy keys (base64-encoded private keys).
# GitHub requires unique SSH keys per repo, so we use one key per repo.
# Env vars: DEPLOY_KEY_SAAS_BASE64, DEPLOY_KEY_MCP_BASE64, DEPLOY_KEY_CORE_BASE64
# Falls back to DEPLOY_SSH_KEY_BASE64 for backward compatibility (single-key mode).
DEPLOY_KEYS: dict[str, str] = {}
for _repo in ("netentive-saas", "netentive-mcp", "netentive-core"):
    _env_var = f"DEPLOY_KEY_{_repo.split('-')[1].upper()}_BASE64"
    _val = os.environ.get(_env_var, "")
    if _val:
        DEPLOY_KEYS[_repo] = _val
    elif DEPLOY_SSH_KEY_BASE64:
        DEPLOY_KEYS[_repo] = DEPLOY_SSH_KEY_BASE64
# Comma-separated list of trusted reverse proxy IPs for X-Forwarded-For.
# If empty, X-Forwarded-For is ignored and the direct connection IP is used.
TRUSTED_PROXIES = set(
    ip.strip() for ip in os.environ.get("TRUSTED_PROXIES", "").split(",") if ip.strip()
)

# Key format: NET-XXXX-XXXX-XXXX (uppercase hex)
KEY_PATTERN = re.compile(r"^NET-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$")

REPOS = ["netentive-saas", "netentive-mcp", "netentive-core"]
GITHUB_ORG = "danmcrae-dev"

# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS deploy_keys (
    id            TEXT PRIMARY KEY,
    customer_email TEXT,
    created_at    TEXT NOT NULL,
    expires_at    TEXT,
    max_installs  INTEGER NOT NULL DEFAULT 3,
    install_count INTEGER NOT NULL DEFAULT 0,
    revoked       INTEGER NOT NULL DEFAULT 0,
    notes         TEXT
);

CREATE TABLE IF NOT EXISTS key_installs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    key_id      TEXT NOT NULL,
    ip_address  TEXT,
    hostname    TEXT,
    redeemed_at TEXT NOT NULL,
    FOREIGN KEY (key_id) REFERENCES deploy_keys(id)
);
"""


def get_db() -> sqlite3.Connection:
    """Open a SQLite connection with row factory."""
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    # Restrict file permissions — DB contains customer email (PII).
    try:
        os.chmod(DB_PATH, 0o600)
    except OSError:
        pass
    return conn


def init_db() -> None:
    """Create tables if they don't exist."""
    conn = get_db()
    try:
        conn.executescript(SCHEMA_SQL)
        conn.commit()
    finally:
        conn.close()


def utc_now_iso() -> str:
    """Current UTC time in ISO-8601 format."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# Rate limiting (in-memory)
# ---------------------------------------------------------------------------

# {ip: [unix_ts, unix_ts, ...]}
_rate_limit_store: dict[str, list[float]] = {}
RATE_WINDOW_SECONDS = 3600  # 1 hour


def _cleanup_rate_limits() -> None:
    """Remove timestamps older than the rate-limit window."""
    cutoff = time.time() - RATE_WINDOW_SECONDS
    for ip in list(_rate_limit_store):
        _rate_limit_store[ip] = [ts for ts in _rate_limit_store[ip] if ts > cutoff]
        if not _rate_limit_store[ip]:
            del _rate_limit_store[ip]


def _check_rate_limit(ip: str) -> bool:
    """Return True if the IP is within the rate limit, False if exceeded."""
    _cleanup_rate_limits()
    attempts = _rate_limit_store.get(ip, [])
    if len(attempts) >= RATE_LIMIT_PER_HOUR:
        return False
    attempts.append(time.time())
    _rate_limit_store[ip] = attempts
    return True


# ---------------------------------------------------------------------------
# Key validation logic
# ---------------------------------------------------------------------------

def _validate_key(key_id: str) -> tuple[bool, str, Optional[sqlite3.Row]]:
    """
    Validate a key against the database.

    Returns (valid, reason, row).
    """
    conn = get_db()
    try:
        row = conn.execute(
            "SELECT * FROM deploy_keys WHERE id = ?", (key_id,)
        ).fetchone()
        if row is None:
            return False, "invalid", None
        if row["revoked"]:
            return False, "revoked", row
        if row["expires_at"] is not None:
            expires_at = row["expires_at"]
            # Support both "2026-12-31" and full ISO.
            if expires_at.endswith("Z"):
                exp_dt = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
            else:
                # Treat date-only as end of that day.
                exp_dt = datetime.fromisoformat(expires_at).replace(
                    hour=23, minute=59, second=59, tzinfo=timezone.utc
                )
            if datetime.now(timezone.utc) > exp_dt:
                return False, "expired", row
        if row["install_count"] >= row["max_installs"]:
            return False, "max_installs", row
        return True, "", row
    finally:
        conn.close()


def _increment_install(key_id: str) -> None:
    """Increment the install_count for a key."""
    conn = get_db()
    try:
        conn.execute(
            "UPDATE deploy_keys SET install_count = install_count + 1 WHERE id = ?",
            (key_id,),
        )
        conn.commit()
    finally:
        conn.close()


def _record_install(key_id: str, ip: str, hostname: str) -> None:
    """Record an install entry in key_installs."""
    conn = get_db()
    try:
        conn.execute(
            "INSERT INTO key_installs (key_id, ip_address, hostname, redeemed_at) "
            "VALUES (?, ?, ?, ?)",
            (key_id, ip, hostname, utc_now_iso()),
        )
        conn.commit()
    finally:
        conn.close()


def _build_success_response(row: sqlite3.Row) -> dict:
    """Build the success response payload."""
    return {
        "valid": True,
        "deploy_keys": DEPLOY_KEYS,  # {"netentive-saas": "base64key", "netentive-mcp": "base64key", ...}
        "repos": REPOS,
        "github_org": GITHUB_ORG,
        "expires_at": row["expires_at"],
        "install_count": row["install_count"] + 1,
        "max_installs": row["max_installs"],
    }


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(
    title="Netentive Key Server",
    version="1.0.0",
    description="Deployment license key validation for the Netentive platform.",
)

# NOTE: No CORS middleware — this is a machine-to-machine API called from
# curl/deploy scripts, not from browsers. Browser access is not needed.


class KeyRequest(BaseModel):
    key: str = Field(..., max_length=20, description="License key in format NET-XXXX-XXXX-XXXX")
    hostname: Optional[str] = Field(None, max_length=100, description="Client hostname (for redeem)")


@app.on_event("startup")
def _startup() -> None:
    init_db()


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.post("/v1/deploy-key/validate")
async def validate_key(req: KeyRequest, request: Request) -> dict:
    """Validate a deployment key. On success, returns the SSH deploy key."""
    client_ip = _get_client_ip(request)

    if not _check_rate_limit(client_ip):
        raise HTTPException(status_code=429, detail="Rate limit exceeded")

    key_id = req.key.strip().upper()
    if not KEY_PATTERN.match(key_id):
        return {"valid": False, "reason": "invalid"}

    valid, reason, row = _validate_key(key_id)
    if not valid:
        return {"valid": False, "reason": reason}

    _increment_install(key_id)
    # Re-fetch to get updated install_count.
    conn = get_db()
    try:
        updated_row = conn.execute(
            "SELECT * FROM deploy_keys WHERE id = ?", (key_id,)
        ).fetchone()
    finally:
        conn.close()

    return _build_success_response(updated_row)


@app.post("/v1/deploy-key/redeem")
async def redeem_key(req: KeyRequest, request: Request) -> dict:
    """Validate a key and record the install metadata."""
    client_ip = _get_client_ip(request)

    if not _check_rate_limit(client_ip):
        raise HTTPException(status_code=429, detail="Rate limit exceeded")

    key_id = req.key.strip().upper()
    if not KEY_PATTERN.match(key_id):
        return {"valid": False, "reason": "invalid"}

    valid, reason, row = _validate_key(key_id)
    if not valid:
        return {"valid": False, "reason": reason}

    _increment_install(key_id)
    _record_install(key_id, client_ip, req.hostname or "unknown")

    conn = get_db()
    try:
        updated_row = conn.execute(
            "SELECT * FROM deploy_keys WHERE id = ?", (key_id,)
        ).fetchone()
    finally:
        conn.close()

    return _build_success_response(updated_row)


def _get_client_ip(request: Request) -> str:
    """Extract client IP. Only trust X-Forwarded-For from configured proxies."""
    real_ip = request.client.host if request.client else "unknown"
    if TRUSTED_PROXIES and real_ip in TRUSTED_PROXIES:
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            return forwarded.split(",")[0].strip()
    return real_ip


# ---------------------------------------------------------------------------
# Allow running directly: python3 key_server.py
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    host = os.environ.get("KEY_SERVER_HOST", "0.0.0.0")
    port = int(os.environ.get("KEY_SERVER_PORT", "7443"))
    uvicorn.run("key_server:app", host=host, port=port)