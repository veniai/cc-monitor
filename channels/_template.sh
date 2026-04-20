#!/usr/bin/env bash
# Channel plugin template
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
