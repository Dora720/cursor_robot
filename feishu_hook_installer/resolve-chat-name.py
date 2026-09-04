"""Resolve Cursor Agent chat display name by conversation_id.

Looks up local Cursor DBs (no network). Prints the name to stdout.
Exit 0 even when empty so callers can fall back.
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys


def _ro(path: str):
    if not path or not os.path.isfile(path):
        return None
    try:
        return sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    except Exception:
        return None


def from_state_vscdb(cid: str) -> str:
    path = os.path.join(os.environ.get("APPDATA", ""), "Cursor", "User", "globalStorage", "state.vscdb")
    con = _ro(path)
    if not con:
        return ""
    try:
        cur = con.cursor()
        # composerHeaders.value JSON often has "name"
        try:
            row = cur.execute(
                "SELECT value FROM composerHeaders WHERE composerId = ? LIMIT 1",
                (cid,),
            ).fetchone()
            if row and row[0]:
                data = json.loads(row[0])
                name = (data.get("name") or "").strip()
                if name:
                    return name
        except Exception:
            pass
        # cursorDiskKV composerData:{id}
        try:
            row = cur.execute(
                "SELECT value FROM cursorDiskKV WHERE key = ? LIMIT 1",
                (f"composerData:{cid}",),
            ).fetchone()
            if row and row[0]:
                data = json.loads(row[0])
                name = (data.get("name") or data.get("title") or "").strip()
                if name:
                    return name
        except Exception:
            pass
    finally:
        con.close()
    return ""


def from_conversation_search(cid: str) -> str:
    path = os.path.join(
        os.environ.get("APPDATA", ""),
        "Cursor",
        "User",
        "globalStorage",
        "conversation-search.db",
    )
    con = _ro(path)
    if not con:
        return ""
    try:
        row = con.execute(
            "SELECT title FROM conversations WHERE id = ? LIMIT 1",
            (cid,),
        ).fetchone()
        if row and row[0]:
            return str(row[0]).strip()
    except Exception:
        pass
    finally:
        con.close()
    return ""


def main() -> int:
    cid = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
    if not cid:
        return 0
    name = from_state_vscdb(cid) or from_conversation_search(cid)
    if name:
        # stdout only the name; hooks capture it
        sys.stdout.write(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
