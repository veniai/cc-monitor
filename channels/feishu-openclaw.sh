#!/usr/bin/env bash
# Feishu channel — via OpenClaw CLI (龙虾模式)

channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  local account target channel

  channel=$(config_get "channel:feishu-openclaw:openclaw_channel" "feishu")
  account=$(config_get "channel:feishu-openclaw:openclaw_account" "")
  target=$(config_get "channel:feishu-openclaw:openclaw_target" "")
  [[ -z "$account" || -z "$target" ]] && return 1

  local msg_with_session
  printf -v msg_with_session '%s\n\n📌 %s' "$full_msg" "${TMUX_SESSION:-unknown}"

  local _i
  for _i in 1 2 3; do
    http_proxy= https_proxy= openclaw message send \
      --channel "$channel" \
      --account "$account" \
      --target "$target" \
      --message "$msg_with_session" >/dev/null && return 0
    sleep 2
  done
  return 1
}
