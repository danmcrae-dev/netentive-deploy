#!/usr/bin/env python3
"""
Netentive Key Manager CLI.

Manage deployment license keys for the Netentive platform.

Commands:
    init     — create database tables
    create   — generate a new license key
    revoke   — revoke an existing key
    list     — list all keys
    info     — show key details and install history
    delete   — delete a key from the database

Usage:
    python3 keymgr.py init
    python3 keymgr.py create --email customer@company.com [--expires 2026-12-31] [--max-installs 3] [--notes "..."]
    python3 keymgr.py revoke NET-XXXX-XXXX-XXXX
    python3 keymgr.py list
    python3 keymgr.py info NET-XXXX-XXXX-XXXX
    python3 keymgr.py delete NET-XXXX-XXXX-XXXX
"""

from __future__ import annotations

import argparse
import os
import secrets
import sqlite3
import sys
from datetime import datetime, timezone

DB_PATH = os.environ.get("DB_PATH", "/data/keys.db")

# ANSI color codes
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
DIM = "\033[2m"
RESET = "\033[0m"

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


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def get_db() -> sqlite3.Connection:
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# Key generation
# ---------------------------------------------------------------------------

def generate_key() -> str:
    """
    Generate a key in format NET-XXXX-XXXX-XXXX
    where X is uppercase hex (4 chars per group after NET).
    """
    # NET is the first group (3 chars). The remaining 3 groups are 4 hex chars each.
    # Actually the spec says "4 groups of 4 hex chars, first group always NET".
    # NET is 3 chars, so the key format is NET-XXXX-XXXX-XXXX (3+4+4+4 = 15 chars).
    group2 = secrets.token_hex(2).upper()  # 4 hex chars
    group3 = secrets.token_hex(2).upper()  # 4 hex chars
    group4 = secrets.token_hex(2).upper()  # 4 hex chars
    return f"NET-{group2}-{group3}-{group4}"


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_init(args: argparse.Namespace) -> None:
    conn = get_db()
    try:
        conn.executescript(SCHEMA_SQL)
        conn.commit()
        print(f"{GREEN}Database initialized at {DB_PATH}{RESET}")
    finally:
        conn.close()


def cmd_create(args: argparse.Namespace) -> None:
    conn = get_db()
    try:
        # Ensure tables exist.
        conn.executescript(SCHEMA_SQL)
        conn.commit()

        key = generate_key()
        created_at = utc_now_iso()
        # Treat "never" (case-insensitive) as no expiry → store NULL.
        if args.expires and args.expires.strip().lower() != "never":
            expires_at = args.expires + "T23:59:59Z"
        else:
            expires_at = None

        conn.execute(
            """INSERT INTO deploy_keys
               (id, customer_email, created_at, expires_at, max_installs, install_count, revoked, notes)
               VALUES (?, ?, ?, ?, ?, 0, 0, ?)""",
            (key, args.email, created_at, expires_at, args.max_installs, args.notes),
        )
        conn.commit()
        print(f"{GREEN}{BOLD}{key}{RESET}")
        print(f"  Email:        {args.email}")
        print(f"  Created:      {created_at}")
        if expires_at:
            print(f"  Expires:      {expires_at}")
        print(f"  Max installs: {args.max_installs}")
        if args.notes:
            print(f"  Notes:        {args.notes}")
    finally:
        conn.close()


def cmd_revoke(args: argparse.Namespace) -> None:
    key_id = args.key.strip().upper()
    conn = get_db()
    try:
        row = conn.execute("SELECT id FROM deploy_keys WHERE id = ?", (key_id,)).fetchone()
        if row is None:
            print(f"{RED}Error: Key {key_id} not found.{RESET}")
            sys.exit(1)
        conn.execute("UPDATE deploy_keys SET revoked = 1 WHERE id = ?", (key_id,))
        conn.commit()
        print(f"{GREEN}Key {key_id} has been revoked.{RESET}")
    finally:
        conn.close()


def cmd_list(args: argparse.Namespace) -> None:
    conn = get_db()
    try:
        rows = conn.execute(
            "SELECT * FROM deploy_keys ORDER BY created_at DESC"
        ).fetchall()
        if not rows:
            print(f"{DIM}No keys found. Use 'create' to generate one.{RESET}")
            return

        # Column definitions: (header, key, width)
        cols = [
            ("KEY", "id", 20),
            ("EMAIL", "customer_email", 28),
            ("CREATED", "created_at", 21),
            ("EXPIRES", "expires_at", 21),
            ("MAX", "max_installs", 5),
            ("USED", "install_count", 5),
            ("REVOKED", "revoked", 8),
            ("NOTES", "notes", 30),
        ]

        # Header
        header = "  ".join(h.ljust(w) for (h, _, w) in cols)
        print(f"{BOLD}{header}{RESET}")
        print("-" * len(header))

        for r in rows:
            values = []
            for (header, key, width) in cols:
                val = str(r[key] or "")
                if header == "REVOKED":
                    val = "YES" if r[key] else "no"
                if header == "EXPIRES" and r[key] is None:
                    val = "never"
                val = val[:width]
                values.append(val.ljust(width))
            line = "  ".join(values)
            if r["revoked"]:
                line = f"{RED}{line}{RESET}"
            print(line)

        print(f"\n{DIM}{len(rows)} key(s) total{RESET}")
    finally:
        conn.close()


def cmd_info(args: argparse.Namespace) -> None:
    key_id = args.key.strip().upper()
    conn = get_db()
    try:
        row = conn.execute("SELECT * FROM deploy_keys WHERE id = ?", (key_id,)).fetchone()
        if row is None:
            print(f"{RED}Error: Key {key_id} not found.{RESET}")
            sys.exit(1)

        print(f"{BOLD}Key:{RESET}         {CYAN}{row['id']}{RESET}")
        print(f"{BOLD}Email:{RESET}       {row['customer_email']}")
        print(f"{BOLD}Created:{RESET}     {row['created_at']}")
        print(f"{BOLD}Expires:{RESET}     {row['expires_at'] or 'never'}")
        print(f"{BOLD}Max installs:{RESET} {row['max_installs']}")
        print(f"{BOLD}Installs:{RESET}    {row['install_count']}")
        print(f"{BOLD}Revoked:{RESET}     {'YES' if row['revoked'] else 'no'}")
        print(f"{BOLD}Notes:{RESET}       {row['notes'] or '-'}")

        # Install history
        installs = conn.execute(
            "SELECT * FROM key_installs WHERE key_id = ? ORDER BY redeemed_at DESC",
            (key_id,),
        ).fetchall()

        print(f"\n{BOLD}Install History ({len(installs)}):{RESET}")
        if installs:
            print(f"  {'ID':<6}  {'IP ADDRESS':<18}  {'HOSTNAME':<24}  {'REDEEMED AT'}")
            print(f"  {'-'*6}  {'-'*18}  {'-'*24}  {'-'*21}")
            for inst in installs:
                print(
                    f"  {str(inst['id']):<6}  "
                    f"{str(inst['ip_address'] or ''):<18}  "
                    f"{str(inst['hostname'] or ''):<24}  "
                    f"{inst['redeemed_at']}"
                )
        else:
            print(f"  {DIM}No installs recorded.{RESET}")
    finally:
        conn.close()


def cmd_delete(args: argparse.Namespace) -> None:
    key_id = args.key.strip().upper()
    conn = get_db()
    try:
        row = conn.execute("SELECT * FROM deploy_keys WHERE id = ?", (key_id,)).fetchone()
        if row is None:
            print(f"{RED}Error: Key {key_id} not found.{RESET}")
            sys.exit(1)

        # Show key details before confirming.
        print(f"  Key:    {row['id']}")
        print(f"  Email:  {row['customer_email']}")
        print(f"  Used:   {row['install_count']}/{row['max_installs']}")
        if not args.force:
            print(f"\n{YELLOW}This will permanently delete the key and all install records.{RESET}")
            confirm = input(f"Type the key ID to confirm deletion: ")
            if confirm.strip().upper() != key_id:
                print(f"{RED}Confirmation did not match. Aborting.{RESET}")
                return

        # Delete install records first (FK), then the key.
        conn.execute("DELETE FROM key_installs WHERE key_id = ?", (key_id,))
        conn.execute("DELETE FROM deploy_keys WHERE id = ?", (key_id,))
        conn.commit()
        print(f"{GREEN}Key {key_id} deleted.{RESET}")
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# CLI setup
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="keymgr",
        description="Netentive deployment key manager.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # init
    p_init = sub.add_parser("init", help="Create database tables")
    p_init.set_defaults(func=cmd_init)

    # create
    p_create = sub.add_parser("create", help="Generate a new license key")
    p_create.add_argument("--email", required=True, help="Customer email")
    p_create.add_argument("--expires", default=None, help="Expiry date (YYYY-MM-DD) or 'never' for no expiry")
    p_create.add_argument("--max-installs", type=int, default=3, help="Max install count (default: 3)")
    p_create.add_argument("--notes", default=None, help="Free-form notes")
    p_create.set_defaults(func=cmd_create)

    # revoke
    p_revoke = sub.add_parser("revoke", help="Revoke a key")
    p_revoke.add_argument("key", help="Key ID to revoke")
    p_revoke.set_defaults(func=cmd_revoke)

    # list
    p_list = sub.add_parser("list", help="List all keys")
    p_list.set_defaults(func=cmd_list)

    # info
    p_info = sub.add_parser("info", help="Show key details and install history")
    p_info.add_argument("key", help="Key ID")
    p_info.set_defaults(func=cmd_info)

    # delete
    p_delete = sub.add_parser("delete", help="Delete a key from the database")
    p_delete.add_argument("key", help="Key ID to delete")
    p_delete.add_argument("--force", action="store_true", help="Skip confirmation")
    p_delete.set_defaults(func=cmd_delete)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()