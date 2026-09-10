"""Resolve Cursor Agent chat display name by conversation_id.

Prefers composerHeaders/composerData chat title, then Agents project name,
then conversation-search title (workspace folder is last-resort in hooks).
Prints the name to stdout. Exit 0 even when empty so callers can fall back.
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys


def _state_vscdb_paths():
    paths = []
    appdata = os.environ.get("APPDATA") or ""
    if appdata:
        paths.append(os.path.join(appdata, "Cursor", "User", "globalStorage", "state.vscdb"))
    # Linux / remote SSH Cursor
    home = os.path.expanduser("~")
    paths.append(os.path.join(home, ".config", "Cursor", "User", "globalStorage", "state.vscdb"))
    paths.append(os.path.join(home, ".cursor-server", "data", "User", "globalStorage", "state.vscdb"))
    out = []
    seen = set()
    for p in paths:
        if p and p not in seen:
            seen.add(p)
            out.append(p)
    return out


def _conversation_search_paths():
    paths = []
    appdata = os.environ.get("APPDATA") or ""
    if appdata:
        paths.append(os.path.join(appdata, "Cursor", "User", "globalStorage", "conversation-search.db"))
    home = os.path.expanduser("~")
    paths.append(os.path.join(home, ".config", "Cursor", "User", "globalStorage", "conversation-search.db"))
    out = []
    seen = set()
    for p in paths:
        if p and p not in seen:
            seen.add(p)
            out.append(p)
    return out


def _ro(path: str):
    if not path or not os.path.isfile(path):
        return None
    try:
        return sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    except Exception:
        return None


def _basename_path(p: str) -> str:
    p = (p or "").replace("\\", "/").rstrip("/")
    if not p:
        return ""
    return os.path.basename(p)


def from_agents_window_label(cid: str) -> str:
    """Agents Window project title for this conversation (not workspace folder leaf)."""
    for path in _state_vscdb_paths():
        con = _ro(path)
        if not con:
            continue
        try:
            cur = con.cursor()
            memb_row = cur.execute(
                "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
                ("glass.localAgentProjectMembership.v1",),
            ).fetchone()
            proj_row = cur.execute(
                "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
                ("glass.localAgentProjects.v1",),
            ).fetchone()
            if not memb_row or not proj_row:
                continue
            memb = json.loads(memb_row[0] or "{}")
            projs = json.loads(proj_row[0] or "[]")
            pid = memb.get(cid)
            if not pid:
                continue
            for p in projs:
                if not isinstance(p, dict) or p.get("id") != pid:
                    continue
                # Prefer project/chat title shown in Agents list.
                pname = (p.get("name") or "").strip()
                if pname:
                    return pname
                ws = (p.get("workspace") or {}).get("uri") or {}
                leaf = _basename_path(ws.get("fsPath") or "")
                if leaf:
                    return leaf
        except Exception:
            pass
        finally:
            con.close()
    return ""


def from_composer_name(cid: str) -> str:
    for path in _state_vscdb_paths():
        con = _ro(path)
        if not con:
            continue
        try:
            cur = con.cursor()
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
    for path in _conversation_search_paths():
        con = _ro(path)
        if not con:
            continue
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
    # Prefer Agent chat title (composer name), then Agents project title, then search DB.
    name = (
        from_composer_name(cid)
        or from_agents_window_label(cid)
        or from_conversation_search(cid)
    )
    if name:
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
        sys.stdout.write(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
