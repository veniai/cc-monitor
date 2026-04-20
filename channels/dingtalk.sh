#!/usr/bin/env bash
# DingTalk channel plugin

channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  local webhook secret

  webhook=$(config_get "channel:dingtalk:webhook" "")
  secret=$(config_get "channel:dingtalk:secret" "")
  [[ -z "$webhook" ]] && return 1

  # DingTalk uses short_msg (designed for smartwatch/glance display)
  # Ensure keyword (~) is present for DingTalk bot filter
  [[ "$short_msg" != *'~'* ]] && short_msg="~ ${short_msg}"

  local url="$webhook"
  if [[ -n "$secret" ]]; then
    if ! command -v python3 >/dev/null 2>&1; then
      echo "[cc-monitor] DingTalk signing requires python3" >&2
      return 1
    fi
    local timestamp sign
    timestamp=$(printf '%.0f' "$(date +%s%3N)")
    sign=$(printf '%s\n%s' "$timestamp" "$secret" \
      | openssl dgst -sha256 -hmac "$secret" -binary \
      | base64 | python3 -c "import sys,urllib.parse;print(urllib.parse.quote_plus(sys.stdin.read().strip()))")
    url="${webhook}&timestamp=${timestamp}&sign=${sign}"
  fi

  local payload
  payload=$(jq -n --arg text "$short_msg" '{msgtype:"text",text:{content:$text}}')
  curl -sf -X POST "$url" \
    -H 'Content-Type: application/json' \
    -d "$payload" | jq -e '.errcode == 0' >/dev/null 2>&1
}
