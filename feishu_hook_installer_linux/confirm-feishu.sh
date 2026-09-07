#!/usr/bin/env bash
# Peer confirm for Linux / Remote SSH (same idea as Windows):
# 1) Send Feishu card
# 2) Immediately return permission=ask (local Cursor Agent window can confirm now)
# 3) Detached watcher: if Feishu decides first, record on server (card updates).
#    Note: Remote cannot UIA-click the local Agent window; if Feishu wins first,
#    click Allow once in the local Agent UI to continue.
set -u
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOOK_DIR/notify-feishu.log"
ENV_FILE="$HOOK_DIR/notify.env"

log() {
  printf '[%s] confirm %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true
}

read_stdin() {
  if [ -t 0 ]; then
    printf ''
  else
    cat
  fi
}

write_perm() {
  printf '{"permission":"%s","continue":true}\n' "$1"
}

py_json_get() {
  local json="$1" key="$2"
  RAW_JSON="$json" KEY="$key" python3 - <<'PY' 2>/dev/null || true
import json, os
d = json.loads(os.environ.get("RAW_JSON") or "{}")
v = d.get(os.environ.get("KEY") or "")
if isinstance(v, list):
    print(v[0] if v else "")
elif v is None:
    print("")
else:
    print(v)
PY
}

load_env() {
  NOTIFY_URL=""
  NOTIFY_TOKEN=""
  [ -f "$ENV_FILE" ] || return 1
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
  done <"$ENV_FILE"
  [ -n "$NOTIFY_URL" ] && [ -n "$NOTIFY_TOKEN" ]
}

RAW="$(read_stdin)"
log "stdin_len=${#RAW}"

if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  write_perm ask
  exit 0
fi

if [ -z "${RAW//[[:space:]]/}" ]; then
  write_perm ask
  exit 0
fi

if ! load_env; then
  log "missing notify.env -> ask only"
  write_perm ask
  exit 0
fi

ID="$(py_json_get "$RAW" conversation_id)"
[ -z "$ID" ] && ID="$(py_json_get "$RAW" session_id)"
[ -z "$ID" ] && ID="local-agent"
WORKSPACE="$(py_json_get "$RAW" workspace_roots)"
CHAT_NAME="$(py_json_get "$RAW" conversation_title)"
[ -z "$CHAT_NAME" ] && CHAT_NAME="$(py_json_get "$RAW" title)"
if [ -z "$CHAT_NAME" ] && [ -n "$WORKSPACE" ]; then
  CHAT_NAME="$(basename "$WORKSPACE")"
fi
DETAIL="$(py_json_get "$RAW" command)"
[ -z "$DETAIL" ] && DETAIL="$(py_json_get "$RAW" tool_name)"
[ -z "$DETAIL" ] && DETAIL="tool"
MACHINE="$(hostname)"

REQ_URL="${NOTIFY_URL%/local-notify}/local-confirm/request"
REQ_TMP="$(mktemp)"
ID="$ID" WORKSPACE="$WORKSPACE" CHAT_NAME="$CHAT_NAME" MACHINE="$MACHINE" DETAIL="$DETAIL" python3 - <<'PY' >"$REQ_TMP"
import json, os
print(json.dumps({
    "id": os.environ.get("ID", ""),
    "conversation_id": os.environ.get("ID", ""),
    "workspace": os.environ.get("WORKSPACE", ""),
    "chat_name": os.environ.get("CHAT_NAME", ""),
    "machine": os.environ.get("MACHINE", ""),
    "detail": os.environ.get("DETAIL", ""),
}, ensure_ascii=False))
PY

REQ_OUT="$(curl -sS -m 30 -X POST "$REQ_URL" \
  -H 'Content-Type: application/json; charset=utf-8' \
  -H "X-Notify-Token: $NOTIFY_TOKEN" \
  --data-binary @"$REQ_TMP" 2>&1 || true)"
rm -f "$REQ_TMP"
log "request: $REQ_OUT"

CONFIRM_ID="$(RAW_JSON="$REQ_OUT" python3 - <<'PY' 2>/dev/null || true
import json, os
d = json.loads(os.environ.get("RAW_JSON") or "{}")
print(d.get("confirm_id") or "")
PY
)"
MESSAGE_ID="$(RAW_JSON="$REQ_OUT" python3 - <<'PY' 2>/dev/null || true
import json, os
d = json.loads(os.environ.get("RAW_JSON") or "{}")
print(d.get("message_id") or "")
PY
)"
AUTO="$(RAW_JSON="$REQ_OUT" python3 - <<'PY' 2>/dev/null || true
import json, os
d = json.loads(os.environ.get("RAW_JSON") or "{}")
print("1" if d.get("auto_allow") or d.get("status") == "allow" else "0")
PY
)"

if [ "$AUTO" = "1" ]; then
  log "auto_allow"
  write_perm allow
  exit 0
fi

# Peer: open Agent-window confirm immediately; Feishu watcher in background.
if [ -n "$CONFIRM_ID" ]; then
  WATCH="$HOOK_DIR/confirm-feishu-watch.sh"
  if [ -x "$WATCH" ] || [ -f "$WATCH" ]; then
    chmod +x "$WATCH" 2>/dev/null || true
    STATUS_URL="${NOTIFY_URL%/local-notify}/local-confirm/status/${CONFIRM_ID}"
    DECIDE_URL="${NOTIFY_URL%/local-notify}/local-confirm/decide"
    nohup bash "$WATCH" \
      --confirm-id "$CONFIRM_ID" \
      --status-url "$STATUS_URL" \
      --decide-url "$DECIDE_URL" \
      --token "$NOTIFY_TOKEN" \
      --message-id "$MESSAGE_ID" \
      --log "$LOG" \
      --timeout 120 \
      >/dev/null 2>&1 &
    log "started watch confirm_id=$CONFIRM_ID message_id=$MESSAGE_ID pid=$!"
  else
    log "watch script missing"
  fi
else
  log "no confirm_id; ask only"
fi

write_perm ask
exit 0
