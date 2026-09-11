#!/usr/bin/env bash
# Manage machine-wide Always Run allowlist for Feishu confirm hooks.
# File: ~/.cursor/hooks/always-run/shared.json
# Usage: bash manage-allowlist.sh list|add|remove|clear|open|path [command]
set -euo pipefail
ACTION="${1:-list}"
CMD="${2:-}"
HOOK_DIR="${HOME}/.cursor/hooks"
ALWAYS_DIR="${HOOK_DIR}/always-run"
SHARED="${ALWAYS_DIR}/shared.json"

list_cmds_py() {
  SHARED="$SHARED" python3 - <<'PY'
import json, os
path = os.environ["SHARED"]
try:
    data = json.load(open(path, encoding="utf-8"))
    for c in data.get("commands") or []:
        if c:
            print(c)
except Exception:
    pass
PY
}

write_cmds_py() {
  # stdin: one command per line
  SHARED="$SHARED" python3 - <<'PY'
import json, os, datetime, sys
from pathlib import Path
path = Path(os.environ["SHARED"])
path.parent.mkdir(parents=True, exist_ok=True)
cmds, seen = [], set()
for line in sys.stdin:
    s = line.strip()
    if s and s not in seen:
        seen.add(s)
        cmds.append(s)
obj = {
    "commands": cmds,
    "scope": "machine",
    "permanent": True,
    "updated_at": datetime.datetime.now().isoformat(timespec="seconds"),
}
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

case "$ACTION" in
  path) echo "$SHARED" ;;
  open)
    mkdir -p "$ALWAYS_DIR"
    [ -f "$SHARED" ] || printf '' | write_cmds_py
    if command -v cursor >/dev/null 2>&1; then cursor -r "$SHARED"
    elif command -v code >/dev/null 2>&1; then code -r "$SHARED"
    else ${EDITOR:-nano} "$SHARED"
    fi
    echo "Opened: $SHARED"
    ;;
  list)
    echo "Allowlist file: $SHARED"
    mapfile -t arr < <(list_cmds_py || true)
    echo "Count: ${#arr[@]}"
    echo "Scope: machine (permanent on this host, no time limit)"
    if [ "${#arr[@]}" -eq 0 ]; then echo "(empty)"; else
      i=1; for c in "${arr[@]}"; do echo "$i. $c"; i=$((i+1)); done
    fi
    ;;
  add)
    [ -n "$CMD" ] || { echo "Usage: manage-allowlist.sh add \"command\""; exit 1; }
    mapfile -t arr < <(list_cmds_py || true)
    arr+=("$CMD")
    printf '%s\n' "${arr[@]}" | write_cmds_py
    echo "Added: $CMD"
    ;;
  remove)
    [ -n "$CMD" ] || { echo "Usage: manage-allowlist.sh remove \"command\""; exit 1; }
    mapfile -t arr < <(list_cmds_py || true)
    out=()
    for c in "${arr[@]}"; do [ "$c" = "$CMD" ] || out+=("$c"); done
    printf '%s\n' "${out[@]}" | write_cmds_py
    echo "Removed: $CMD"
    ;;
  clear)
    printf '' | write_cmds_py
    echo "Cleared allowlist: $SHARED"
    ;;
  *)
    echo "Usage: manage-allowlist.sh list|add|remove|clear|open|path [command]"
    exit 1
    ;;
esac