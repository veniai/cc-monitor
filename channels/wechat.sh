#!/usr/bin/env bash
# WeChat channel via OpenClaw CLI

channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  local account target

  account=$(config_get "channel:wechat:account" "")
  target=$(config_get "channel:wechat:target" "")
  [[ -z "$account" || -z "$target" ]] && return 1

  local msg_with_session="${full_msg}\n\n📌 ${TMUX_SESSION:-unknown}"

  local _i
  for _i in 1 2 3; do
    openclaw message send \
      --channel openclaw-weixin \
      --account "$account" \
      --target "$target" \
      --message "$msg_with_session" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
