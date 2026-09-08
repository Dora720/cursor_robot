#!/usr/bin/env bash
# Install Feishu notify hooks for Linux / Cursor Remote SSH.
# Usage (on the remote Linux host):
#   cd feishu_hook_installer_linux
#   cp notify.env.example notify.env   # fill NOTIFY_TOKEN
#   bash install.sh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
CURSOR_DIR="${HOME}/.cursor"
HOOK_DIR="${CURSOR_DIR}/hooks"
mkdir -p "$HOOK_DIR"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

need curl
need python3

for name in notify-feishu.sh confirm-feishu.sh confirm-feishu-watch.sh ping-hook.sh log-rotate.sh resolve-chat-name.py; do
  if [ ! -f "${SRC_DIR}/${name}" ]; then
    echo "ERROR: missing ${SRC_DIR}/${name}" >&2
    exit 1
  fi
  cp -f "${SRC_DIR}/${name}" "${HOOK_DIR}/${name}"
  chmod +x "${HOOK_DIR}/${name}"
done

ENV_DST="${HOOK_DIR}/notify.env"
ENV_SRC="${SRC_DIR}/notify.env"
ENV_EXAMPLE="${SRC_DIR}/notify.env.example"
if [ -f "$ENV_SRC" ]; then
  cp -f "$ENV_SRC" "$ENV_DST"
elif [ ! -f "$ENV_DST" ]; then
  if [ ! -f "$ENV_EXAMPLE" ]; then
    echo "ERROR: missing notify.env and notify.env.example" >&2
    exit 1
  fi
  cp -f "$ENV_EXAMPLE" "$ENV_DST"
  echo "Created ${ENV_DST} from example. Fill NOTIFY_TOKEN before testing."
fi

HOOKS_JSON="${CURSOR_DIR}/hooks.json"
NOTIFY="${HOOK_DIR}/notify-feishu.sh"
CONFIRM="${HOOK_DIR}/confirm-feishu.sh"
PING="${HOOK_DIR}/ping-hook.sh"

# Write hooks.json with absolute script paths (JSON-escaped via python).
NOTIFY="$NOTIFY" CONFIRM="$CONFIRM" PING="$PING" HOOKS_JSON="$HOOKS_JSON" python3 - <<'PY'
import json, os
from pathlib import Path
cfg = {
    "version": 1,
    "hooks": {
        "sessionStart": [
            {"command": os.environ["PING"], "timeout": 15}
        ],
        "stop": [
            {"command": os.environ["NOTIFY"], "timeout": 120}
        ],
        "beforeShellExecution": [
            {"command": os.environ["CONFIRM"], "timeout": 120}
        ],
        "preToolUse": [
            {"command": os.environ["CONFIRM"], "matcher": "Task", "timeout": 120}
        ],
    },
}
Path(os.environ["HOOKS_JSON"]).write_text(
    json.dumps(cfg, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
print(os.environ["HOOKS_JSON"])
PY

LOG="${HOOK_DIR}/notify-feishu.log"
: >"$LOG"
printf '[%s] install probe host=%s user=%s\n' \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$(hostname)" "${USER:-}" >>"$LOG"

echo ""
echo "Installed OK"
echo "  host       : $(hostname)"
echo "  user       : ${USER:-}"
echo "  hooks.json : ${HOOKS_JSON}"
echo "  scripts    : ${HOOK_DIR}"
echo "  log        : ${LOG}"
echo ""

NOTIFY_URL=""
NOTIFY_TOKEN=""
while IFS= read -r line || [ -n "$line" ]; do
  line="${line#"${line%%[![:space:]]*}"}"
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  key="${line%%=*}"
  val="${line#*=}"
  key="$(printf '%s' "$key" | tr -d '\r' | sed 's/[[:space:]]*$//')"
  val="$(printf '%s' "$val" | tr -d '\r')"
  case "$key" in
    NOTIFY_URL) NOTIFY_URL="$val" ;;
    NOTIFY_TOKEN) NOTIFY_TOKEN="$val" ;;
  esac
done <"$ENV_DST"

if [ -n "$NOTIFY_URL" ] && [ -n "$NOTIFY_TOKEN" ]; then
  TMP="$(mktemp)"
  HOST="$(hostname)" USER_NAME="${USER:-}" python3 - <<'PY' >"$TMP"
import json, os
print(json.dumps({
    "event": "statusChange",
    "id": "install-self-test-linux",
    "status": "completed",
    "machine": os.environ.get("HOST", ""),
    "workspace": os.environ.get("USER_NAME", ""),
    "model": "install-test-linux",
    "chat_name": "linux-install-test",
}, ensure_ascii=False))
PY
  echo "Sending Feishu test from $(hostname) ..."
  OUT="$(curl -sS -m 90 -w ' HTTP:%{http_code}' -X POST "$NOTIFY_URL" \
    -H 'Content-Type: application/json; charset=utf-8' \
    -H "X-Notify-Token: $NOTIFY_TOKEN" \
    --data-binary @"$TMP" 2>&1 || true)"
  rm -f "$TMP"
  echo "test result: $OUT"
  printf '[%s] install test %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$OUT" >>"$LOG"
else
  echo "WARNING: notify.env missing URL/token, skipped Feishu test"
fi

echo ""
echo "Next:"
echo "  1. Fully quit local Cursor (tray too), reopen, reconnect Remote SSH."
echo "  2. Settings -> Hooks: confirm stop / beforeShellExecution are listed."
echo "  3. Run one Agent in the remote workspace; check Feishu + ${LOG}"
echo "  4. Confirm is peer: Feishu card and local Agent window appear together (no 90s wait)."
echo "     If you click Feishu first on Remote SSH, also click Allow once in the local Agent UI"
echo "     (remote Linux cannot auto-click the Windows Cursor window)."
