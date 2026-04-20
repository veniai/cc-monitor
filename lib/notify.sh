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
    channel_send "$full_msg" "$short_msg" || true
  done
}
