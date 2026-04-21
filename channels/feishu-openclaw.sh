#!/usr/bin/env bash
# Feishu channel — via OpenClaw CLI (龙虾模式)

channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  local account target channel

  channel=$(config_get "channel:feishu-openclaw:openclaw_channel" "openclaw-feishu")
  account=$(config_get "channel:feishu-openclaw:openclaw_account" "")
  target=$(config_get "channel:feishu-openclaw:openclaw_target" "")
  [[ -z "$account" || -z "$target" ]] && return 1

  local msg_with_session="${full_msg}\n\n📌 ${TMUX_SESSION:-unknown}"

  local _i
  for _i in 1 2 3; do
    openclaw message send \
      --channel "$channel" \
      --account "$account" \
      --target "$target" \
      --message "$msg_with_session" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
