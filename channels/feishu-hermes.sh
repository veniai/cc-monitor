#!/usr/bin/env bash
# Feishu channel — feishu-cli (Hermes mode)

channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  local app_id app_secret receive_id receive_id_type

  app_id=$(config_get "channel:feishu-hermes:app_id" "")
  app_secret=$(config_get "channel:feishu-hermes:app_secret" "")
  receive_id=$(config_get "channel:feishu-hermes:receive_id" "")
  receive_id_type=$(config_get "channel:feishu-hermes:receive_id_type" "open_id")
  [[ -z "$app_id" || -z "$app_secret" || -z "$receive_id" ]] && return 1

  local msg_with_session
  printf -v msg_with_session '%s\n\n📌 %s' "$full_msg" "${TMUX_SESSION:-unknown}"

  local feishu_cli
  feishu_cli=$(command -v feishu-cli 2>/dev/null) || true
  [[ -z "$feishu_cli" ]] && { echo "feishu-cli not found in PATH" >&2; return 1; }

  FEISHU_APP_ID="$app_id" FEISHU_APP_SECRET="$app_secret" \
    "$feishu_cli" msg send \
      --receive-id-type "$receive_id_type" \
      --receive-id "$receive_id" \
      --text "$msg_with_session"
}
