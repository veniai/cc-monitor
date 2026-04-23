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

    # shellcheck source=/dev/null
    source "$plugin"
    if ! channel_send "$full_msg" "$short_msg" 2>"${MARKER_DIR:-/tmp/cc-monitor}/debug/notify-${channel_name}-$(date +%s).log"; then
      echo "[$(date '+%H:%M:%S')] $channel_name 通知发送失败" >> "${MARKER_DIR:-/tmp/cc-monitor}/debug/notify-failures.log"
    fi
  done
}
