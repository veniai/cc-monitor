#!/usr/bin/env bash
# Feishu/Lark channel plugin

channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  local webhook

  webhook=$(config_get "channel:feishu:webhook" "")
  [[ -z "$webhook" ]] && return 1

  local payload
  payload=$(jq -n --arg text "$short_msg" '{msg_type:"text",content:{text:$text}}')
  curl -sf -X POST "$webhook" \
    -H 'Content-Type: application/json' \
    -d "$payload" | jq -e '.code == 0' >/dev/null 2>&1
}
