#!/usr/bin/env bash
# NOTE: this file must use LF line endings (not CRLF).
# sessionStart probe for Linux / Remote SSH hooks.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOOK_DIR/notify-feishu.log"
# shellcheck source=/dev/null
[ -f "$HOOK_DIR/log-rotate.sh" ] && . "$HOOK_DIR/log-rotate.sh"
if type rotate_notify_log >/dev/null 2>&1; then
  rotate_notify_log "$LOG" || true
fi
printf '[%s] cmd invoked event=sessionStart host=%s user=%s\n' \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$(hostname)" "${USER:-}" >>"$LOG" 2>/dev/null || true
printf '%s\n' '{}'
exit 0
