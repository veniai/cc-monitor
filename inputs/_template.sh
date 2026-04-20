#!/usr/bin/env bash
# Input plugin template
#
# To create a new input source:
# 1. Copy this file to inputs/<name>.sh
# 2. Implement input_poll()
# 3. Add [input:<name>] section to config.example.conf

input_poll() {
  # Output JSON array to stdout:
  # [{id, sender_id, chat_id, text, timestamp, channel}]
  # Return 0 on success, 1 on failure
  echo '[]'
  return 1
}
