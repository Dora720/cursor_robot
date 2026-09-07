#!/usr/bin/env bash
# Notify Feishu when a Cursor Agent turn stops (Linux / Remote SSH).
set -u
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOOK_DIR/notify-feishu.log"
ENV_FILE="$HOOK_DIR/notify.env"
# shellcheck source=/dev/null
[ -f "$HOOK_DIR/log-rotate.sh" ] && . "$HOOK_DIR/log-rotate.sh"

log() {
  if type rotate_notify_log >/dev/null 2>&1; then
    rotate_notify_log "$LOG" || true
  fi
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true
}

read_stdin() {
  if [ -t 0 ]; then
    printf ''
  else
    cat
  fi
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

need_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log "missing binary: $1"
    return 1
  }
}

RAW="$(read_stdin)"
log "hook start host=$(hostname) user=${USER:-} stdin_len=${#RAW}"

if ! need_bin curl || ! need_bin python3; then
  printf '%s\n' '{}'
  exit 0
fi

if [ -z "${RAW//[[:space:]]/}" ]; then
  log "empty stdin, skip"
  printf '%s\n' '{}'
  exit 0
fi

EVENT="$(py_json_get "$RAW" hook_event_name)"
if [ "$EVENT" = "sessionEnd" ]; then
  log "skip sessionEnd"
  printf '%s\n' '{}'
  exit 0
fi

STATUS="$(py_json_get "$RAW" status)"
[ -z "$STATUS" ] && STATUS="$(py_json_get "$RAW" final_status)"
case "$STATUS" in
  aborted|window_close|user_close)
    log "skip status=$STATUS"
    printf '%s\n' '{}'
    exit 0
    ;;
esac
[ -z "$STATUS" ] && STATUS="completed"

if ! load_env; then
  log "missing or bad notify.env"
  printf '%s\n' '{}'
  exit 0
fi

ID="$(py_json_get "$RAW" conversation_id)"
[ -z "$ID" ] && ID="$(py_json_get "$RAW" session_id)"
[ -z "$ID" ] && ID="local-agent"

WORKSPACE="$(py_json_get "$RAW" workspace_roots)"
MODEL="$(py_json_get "$RAW" model)"
CHAT_NAME="$(py_json_get "$RAW" conversation_title)"
[ -z "$CHAT_NAME" ] && CHAT_NAME="$(py_json_get "$RAW" title)"
if [ -z "$CHAT_NAME" ] && [ -n "$WORKSPACE" ]; then
  CHAT_NAME="$(basename "$WORKSPACE")"
fi
MACHINE="$(hostname)"

TMP="$(mktemp)"
RAW_JSON="$RAW" ID="$ID" STATUS="$STATUS" MACHINE="$MACHINE" WORKSPACE="$WORKSPACE" MODEL="$MODEL" CHAT_NAME="$CHAT_NAME" python3 - <<'PY' >"$TMP"
import json, os
raw = {}
try:
    raw = json.loads(os.environ.get("RAW_JSON") or "{}")
except Exception:
    raw = {}
out = {
    "event": "statusChange",
    "id": os.environ.get("ID", ""),
    "conversation_id": os.environ.get("ID", ""),
    "status": os.environ.get("STATUS", ""),
    "machine": os.environ.get("MACHINE", ""),
    "workspace": os.environ.get("WORKSPACE", ""),
    "model": os.environ.get("MODEL", ""),
    "chat_name": os.environ.get("CHAT_NAME", ""),
}
for key in ("loop_count", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"):
    if key in raw and raw[key] is not None:
        out[key] = raw[key]
print(json.dumps(out, ensure_ascii=False))
PY

log "post $NOTIFY_URL id=$ID status=$STATUS"
HTTP_BODY="$(curl -sS -m 120 -w '\n%{http_code}' -X POST "$NOTIFY_URL" \
  -H 'Content-Type: application/json; charset=utf-8' \
  -H "X-Notify-Token: $NOTIFY_TOKEN" \
  --data-binary @"$TMP" 2>&1 || true)"
log "curl: $HTTP_BODY"
rm -f "$TMP"

TAKE_URL="${NOTIFY_URL%/local-notify}/local-followup/take"
TAKE_TMP="$(mktemp)"
ID="$ID" python3 - <<'PY' >"$TAKE_TMP"
import json, os
cid = os.environ.get("ID", "")
print(json.dumps({"conversation_id": cid, "id": cid}, ensure_ascii=False))
PY
TAKE_OUT="$(curl -sS -m 20 -X POST "$TAKE_URL" \
  -H 'Content-Type: application/json; charset=utf-8' \
  -H "X-Notify-Token: $NOTIFY_TOKEN" \
  --data-binary @"$TAKE_TMP" 2>&1 || true)"
rm -f "$TAKE_TMP"
log "followup take: $TAKE_OUT"

FOLLOW_TEXT="$(RAW_JSON="$TAKE_OUT" python3 - <<'PY' 2>/dev/null || true
import json, os
d = json.loads(os.environ.get("RAW_JSON") or "{}")
print(d.get("text") or "")
PY
)"

if [ -n "$FOLLOW_TEXT" ]; then
  FOLLOW_TEXT="$FOLLOW_TEXT" python3 - <<'PY'
import json, os
print(json.dumps({"followup_message": os.environ.get("FOLLOW_TEXT", "")}, ensure_ascii=False))
PY
else
  printf '%s\n' '{}'
fi
exit 0
