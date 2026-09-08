#!/usr/bin/env bash
# NOTE: this file must use LF line endings (not CRLF).
# Background watcher: Feishu decision updates server/card.
# Remote Linux cannot click the local Cursor Agent Allow button (no UIA).
set -u

CONFIRM_ID=""
STATUS_URL=""
DECIDE_URL=""
TOKEN=""
MESSAGE_ID=""
LOG=""
TIMEOUT=120

while [ $# -gt 0 ]; do
  case "$1" in
    --confirm-id) CONFIRM_ID="$2"; shift 2 ;;
    --status-url) STATUS_URL="$2"; shift 2 ;;
    --decide-url) DECIDE_URL="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --message-id) MESSAGE_ID="$2"; shift 2 ;;
    --log) LOG="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

log() {
  [ -n "$LOG" ] || return 0
  HOOK_DIR_FOR_LOG="$(cd "$(dirname "$LOG")" 2>/dev/null && pwd)"
  # shellcheck source=/dev/null
  [ -n "$HOOK_DIR_FOR_LOG" ] && [ -f "$HOOK_DIR_FOR_LOG/log-rotate.sh" ] && . "$HOOK_DIR_FOR_LOG/log-rotate.sh"
  if type rotate_notify_log >/dev/null 2>&1; then
    rotate_notify_log "$LOG" || true
  fi
  printf '[%s] watch %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true
}

[ -n "$CONFIRM_ID" ] && [ -n "$STATUS_URL" ] && [ -n "$TOKEN" ] || exit 0

CLAIM="/tmp/cursor-confirm-watch-${CONFIRM_ID}.lock"
if ! (set -o noclobber; echo $$ >"$CLAIM") 2>/dev/null; then
  log "another watcher already claimed; exit"
  exit 0
fi
trap 'rm -f "$CLAIM"' EXIT

log "start confirm_id=$CONFIRM_ID timeout=$TIMEOUT message_id=$MESSAGE_ID"

i=0
while [ "$i" -lt "$TIMEOUT" ]; do
  sleep 1
  i=$((i + 1))
  ST_OUT="$(curl -sS -m 8 -H "X-Notify-Token: $TOKEN" "$STATUS_URL" 2>&1 || true)"
  ST="$(RAW_JSON="$ST_OUT" python3 - <<'PY' 2>/dev/null || true
import json, os
d = json.loads(os.environ.get("RAW_JSON") or "{}")
print(d.get("status") or "")
PY
)"
  case "$ST" in
    allow|always|deny|cursor)
      log "status=$ST (Feishu or Agent/server already decided)"
      # Feishu button already patched the card via callback when allow/always/deny.
      # cursor means Agent/server won; card should already be updating.
      exit 0
      ;;
  esac
done

log "watch end without terminal status"
exit 0
