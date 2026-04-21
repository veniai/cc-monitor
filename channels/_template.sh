#!/usr/bin/env bash
# Channel plugin template
#
# Supports dual-mode: webhook (direct HTTP) or openclaw (龙虾模式 via CLI).
# Choose one per channel file — do not mix modes in the same plugin.
#
# To create a new channel:
# 1. Copy this file to channels/<name>.sh
# 2. Implement channel_send()
# 3. Add [channel:<name>] section to config.example.conf
#
# Required config:
#   [channel:<name>]
#   enabled=true
#   # channel-specific fields

channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  # Implement: send notification to this channel
  # Return 0 on success, 1 on failure
  return 1
}
