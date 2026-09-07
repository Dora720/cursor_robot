#!/usr/bin/env bash
# sessionStart probe for Linux / Remote SSH hooks.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOOK_DIR/notify-feishu.log"
printf '[%s] cmd invoked event=sessionStart host=%s user=%s\n' \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$(hostname)" "${USER:-}" >>"$LOG" 2>/dev/null || true
printf '%s\n' '{}'
exit 0
