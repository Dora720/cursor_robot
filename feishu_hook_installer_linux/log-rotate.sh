#!/usr/bin/env bash
# NOTE: this file must use LF line endings (not CRLF).
# Shared log rotation: keep notify-feishu.log under ~1MB (discard older bytes).
# Usage: source this file, then call rotate_notify_log "$LOG" before append.
LOG_MAX_BYTES="${LOG_MAX_BYTES:-1048576}"
LOG_KEEP_BYTES="${LOG_KEEP_BYTES:-614400}"

rotate_notify_log() {
  local path="${1:-}"
  [ -n "$path" ] && [ -f "$path" ] || return 0
  local sz
  sz="$(wc -c <"$path" 2>/dev/null | tr -d ' ')"
  case "$sz" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$sz" -le "$LOG_MAX_BYTES" ] && return 0
  local tmp="${path}.rotate.$$"
  {
    printf '[%s] ---- log truncated (max 1MB, old lines discarded) ----\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    # Prefer line-oriented tail when available; fallback to byte tail.
    if tail -n +1 "$path" >/dev/null 2>&1; then
      # Keep roughly last 600KB of content.
      tail -c "$LOG_KEEP_BYTES" "$path" 2>/dev/null | tail -n +2
    else
      tail -c "$LOG_KEEP_BYTES" "$path" 2>/dev/null
    fi
  } >"$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}
