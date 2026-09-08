#!/usr/bin/env bash
# NOTE: this file must use LF line endings (not CRLF).
# Uninstall Feishu notify hooks on Linux / Cursor Remote SSH.
# Usage:
#   cd feishu_hook_installer_linux
#   bash uninstall.sh
set -euo pipefail

CURSOR_DIR="${HOME}/.cursor"
HOOK_DIR="${CURSOR_DIR}/hooks"
HOOKS_JSON="${CURSOR_DIR}/hooks.json"

echo "Uninstalling Cursor Feishu hook (Linux)..."
echo "  host : $(hostname)"
echo "  user : ${USER:-}"
echo ""

# Stop background watchers started by confirm-feishu.sh
pkill -f "confirm-feishu-watch.sh" 2>/dev/null || true
rm -f /tmp/cursor-confirm-watch-*.lock 2>/dev/null || true

if [ -f "$HOOKS_JSON" ]; then
  BAK="${CURSOR_DIR}/hooks.json.bak-uninstall-$(date +%Y%m%d-%H%M%S)"
  cp -f "$HOOKS_JSON" "$BAK"
  echo "Backed up hooks.json -> $BAK"
  rm -f "$HOOKS_JSON"
  echo "Removed hooks.json"
fi

REMOVED=0
for name in \
  notify-feishu.sh \
  confirm-feishu.sh \
  confirm-feishu-watch.sh \
  ping-hook.sh \
  notify-feishu.log \
  notify.env
do
  path="${HOOK_DIR}/${name}"
  if [ -e "$path" ]; then
    rm -f "$path"
    REMOVED=$((REMOVED + 1))
  fi
done

echo ""
echo "Uninstall OK"
echo "  removed hook files : ${REMOVED}"
echo "  hooks dir          : ${HOOK_DIR}"
echo ""
echo "Next:"
echo "  1. Fully quit local Cursor (tray too), reopen, reconnect Remote SSH."
echo "  2. Settings -> Hooks should no longer list these scripts."
echo ""
