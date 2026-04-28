#!/usr/bin/env bash
# Notification dispatcher for cc-monitor

[[ -n "${_NOTIFY_LOADED:-}" ]] && return 0
_NOTIFY_LOADED=1

# Send notification through all enabled channels
notify_user() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"

  local plugin channel_name enabled
  for plugin in "$SCRIPT_DIR/channels/"*.sh; do
    [[ -f "$plugin" ]] || continue
    channel_name=$(basename "$plugin" .sh)
    [[ "$channel_name" == _* ]] && continue  # skip templates

    enabled=$(config_get "channel:${channel_name}:enabled" "false")
    [[ "$enabled" != "true" ]] && continue

    local err_log="${MARKER_DIR:-/tmp/cc-monitor}/debug/notify-${channel_name}-$(date +%s).log"
    # shellcheck source=/dev/null
    source "$plugin"
    if ! channel_send "$full_msg" "$short_msg" 2>"$err_log"; then
      local err_detail=""
      if [[ -f "$err_log" && -s "$err_log" ]]; then
        err_detail=$(head -1 "$err_log")
      fi
      if [[ -n "$err_detail" ]]; then
        echo "[$(date '+%H:%M:%S')] $channel_name 通知发送失败: $err_detail" >> "${MARKER_DIR:-/tmp/cc-monitor}/debug/notify-failures.log"
      else
        echo "[$(date '+%H:%M:%S')] $channel_name 通知发送失败 (无错误详情)" >> "${MARKER_DIR:-/tmp/cc-monitor}/debug/notify-failures.log"
      fi
    fi
  done
}
