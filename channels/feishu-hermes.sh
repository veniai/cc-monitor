#!/usr/bin/env bash
# Feishu channel — feishu-cli (Hermes mode)
# Sends interactive card messages for proper Markdown rendering

channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  local app_id app_secret receive_id receive_id_type
  local session_name="${TMUX_SESSION:-unknown}"

  app_id=$(config_get "channel:feishu-hermes:app_id" "")
  app_secret=$(config_get "channel:feishu-hermes:app_secret" "")
  receive_id=$(config_get "channel:feishu-hermes:receive_id" "")
  receive_id_type=$(config_get "channel:feishu-hermes:receive_id_type" "open_id")
  [[ -z "$app_id" || -z "$app_secret" || -z "$receive_id" ]] && return 1

  # Derive color from notification type
  local color="blue"
  if [[ "$short_msg" == *"✓"* || "$short_msg" == *"完成"* ]]; then
    color="green"
  elif [[ "$short_msg" == *"✗"* || "$short_msg" == *"错误"* ]]; then
    color="red"
  elif [[ "$short_msg" == *"⚠"* || "$short_msg" == *"API"* ]]; then
    color="orange"
  elif [[ "$short_msg" == *"⏸"* || "$short_msg" == *"限额"* ]]; then
    color="yellow"
  fi

  # Use short_msg as card header, full_msg as card body
  local header_title
  header_title="${short_msg:-$session_name}"

  # Build interactive card JSON
  local card_json
  card_json=$(jq -n \
    --arg title "$header_title" \
    --arg color "$color" \
    --arg body "$full_msg" \
    --arg session "$session_name" \
    '{
      config: { wide_screen_mode: true },
      header: {
        title: { tag: "plain_text", content: $title },
        template: $color
      },
      elements: [
        { tag: "markdown", content: "\($body)\n\n📌 \($session)" }
      ]
    }')

  local feishu_cli
  feishu_cli=$(command -v feishu-cli 2>/dev/null) || true
  [[ -z "$feishu_cli" ]] && { echo "feishu-cli not found in PATH" >&2; return 1; }

  FEISHU_APP_ID="$app_id" FEISHU_APP_SECRET="$app_secret" \
    "$feishu_cli" msg send \
      --receive-id-type "$receive_id_type" \
      --receive-id "$receive_id" \
      --msg-type interactive \
      --content "$card_json"
}
