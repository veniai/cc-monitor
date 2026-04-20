#!/usr/bin/env bash
# WeChat input plugin — poll messages via OpenClaw CLI

input_poll() {
  local account
  account=$(config_get "channel:wechat:account" "")
  [[ -z "$account" ]] && { echo '[]'; return 1; }

  local raw
  raw=$(openclaw message receive \
    --channel openclaw-weixin \
    --account "$account" \
    --limit 20 2>/dev/null) || { echo '[]'; return 1; }

  echo "$raw" | jq -c '[.[] | {
    id: (.id // .msgid // (.timestamp | tostring)),
    sender_id: (.sender // .from // ""),
    chat_id: (.chat // .group // ""),
    text: (.text // .content // ""),
    timestamp: (.timestamp // .ts // 0),
    channel: "wechat"
  }]' 2>/dev/null || echo '[]'
}
