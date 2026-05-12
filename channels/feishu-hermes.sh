#!/usr/bin/env bash
# Feishu channel — REST API direct (Hermes mode)

_get_feishu_token() {
  local app_id="$1" app_secret="$2"
  local cache_file="${MARKER_DIR:-/tmp/cc-monitor}/feishu-token.cache"
  local now
  now=$(date +%s)

  # Read cache
  if [[ -f "$cache_file" ]]; then
    local cached_token cached_expires
    cached_token=$(jq -r '.token // empty' "$cache_file" 2>/dev/null)
    cached_expires=$(jq -r '.expires_at // 0' "$cache_file" 2>/dev/null)
    if [[ -n "$cached_token" && $((cached_expires - 30)) -gt "$now" ]]; then
      printf '%s' "$cached_token"
      return 0
    fi
  fi

  # Refresh token
  local resp
  mkdir -p "$(dirname "$cache_file")"
  resp=$(http_proxy= https_proxy= curl -s -X POST \
    "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
    -H "Content-Type: application/json" \
    -d "{\"app_id\":\"$app_id\",\"app_secret\":\"$app_secret\"}")

  local new_token new_expire
  new_token=$(printf '%s' "$resp" | jq -r '.tenant_access_token // empty')
  new_expire=$(printf '%s' "$resp" | jq -r '.expire // 7200')
  [[ -z "$new_token" ]] && return 1

  # Atomic write cache
  local tmp
  tmp="$(mktemp "${cache_file}.XXXXXX")"
  jq -n --arg token "$new_token" --argjson expires $((now + new_expire)) \
    '{token: $token, expires_at: $expires}' > "$tmp"
  mv "$tmp" "$cache_file"

  printf '%s' "$new_token"
}

_feishu_send_message() {
  local token="$1" receive_id="$2" receive_id_type="$3" content="$4"
  local escaped
  escaped=$(printf '%s' "$content" | jq -Rs .)
  http_proxy= https_proxy= curl -s -X POST \
    "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=$receive_id_type" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"receive_id\":\"$receive_id\",\"msg_type\":\"text\",\"content\":$escaped}"
}

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

  local token resp code _i
  for _i in 1 2 3; do
    token=$(_get_feishu_token "$app_id" "$app_secret") || return 1
    resp=$(_feishu_send_message "$token" "$receive_id" "$receive_id_type" "$msg_with_session")
    code=$(printf '%s' "$resp" | jq -r '.code // -1')

    if [[ "$code" == "0" ]]; then
      return 0
    fi

    # Token expired — clear cache and retry immediately on next loop iteration
    if [[ "$code" == "99991668" ]]; then
      rm -f "${MARKER_DIR:-/tmp/cc-monitor}/feishu-token.cache"
      continue
    fi

    sleep $((_i * 2))
  done
  return 1
}
