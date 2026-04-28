#!/usr/bin/env bash
# Feishu/Lark channel plugin (same behavior as wechat: full_msg + session tag + retry)

channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  local webhook

  webhook=$(config_get "channel:feishu:webhook" "")
  [[ -z "$webhook" ]] && return 1

  local msg_with_session
  printf -v msg_with_session '%s\n\n📌 %s' "$full_msg" "${TMUX_SESSION:-unknown}"
  local payload
  payload=$(jq -n --arg text "$msg_with_session" '{msg_type:"text",content:{text:$text}}')

  local _i
  for _i in 1 2 3; do
    curl -sf -X POST "$webhook" \
      -H 'Content-Type: application/json' \
      -d "$payload" | jq -e '.code == 0' >/dev/null && return 0
    sleep 2
  done
  return 1
}
