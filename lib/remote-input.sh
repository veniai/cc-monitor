#!/usr/bin/env bash
# Remote input: command parsing, security, daemon loop

[[ -n "${_REMOTE_INPUT_LOADED:-}" ]] && return 0
_REMOTE_INPUT_LOADED=1

# Parse message text into session + command
# Sets: PARSED_SESSION, PARSED_COMMAND
# Returns 0 if valid, 1 if rejected
parse_command() {
  local text="${1:?text required}"
  PARSED_SESSION=""
  PARSED_COMMAND=""

  # @session command format
  if [[ "$text" =~ ^@([[:graph:]]+)[[:space:]]+(.+)$ ]]; then
    PARSED_SESSION="${BASH_REMATCH[1]}"
    PARSED_COMMAND="${BASH_REMATCH[2]}"
    return 0
  fi

  # status/状态 without @session
  case "$text" in
    status|状态)
      PARSED_COMMAND="$text"
      return 0
      ;;
  esac

  return 1
}

# Check if command is in allowed list
is_command_allowed() {
  local cmd="${1:?command required}"
  local allowed
  allowed=$(config_get "input:wechat:allowed_commands" "继续,continue,停止,stop,状态,status")
  local IFS=','
  local a
  for a in $allowed; do
    [[ "$a" == "$cmd" ]] && return 0
  done
  return 1
}

# Check if sender is allowed (empty whitelist = trust all)
is_sender_allowed() {
  local sender_id="${1:-}" chat_id="${2:-}"
  local allowed_senders allowed_chats
  allowed_senders=$(config_get "input:wechat:allowed_senders" "")
  allowed_chats=$(config_get "input:wechat:allowed_chats" "")

  # Empty = trust all
  [[ -z "$allowed_senders" && -z "$allowed_chats" ]] && return 0

  # Check sender
  if [[ -n "$allowed_senders" ]]; then
    local IFS=',' s
    for s in $allowed_senders; do
      [[ "$s" == "$sender_id" ]] && return 0
    done
  fi

  # Check chat
  if [[ -n "$allowed_chats" ]]; then
    local IFS=',' c
    for c in $allowed_chats; do
      [[ "$c" == "$chat_id" ]] && return 0
    done
  fi

  return 1
}

# Check rate limit per tmux session
# Returns 0 if allowed, 1 if exceeded
check_rate_limit() {
  local session="${1:?session required}"
  local limit
  limit=$(config_get "input:wechat:rate_limit_per_minute" "10")
  limit=$((limit))

  local rate_file="${MARKER_DIR:-/tmp/cc-monitor}/rate-${session}.json"
  local now window count
  now=$(date +%s)
  window=$((now - 60))

  if [[ -f "$rate_file" ]]; then
    count=$(jq -r --argjson w "$window" '[.[] | select(. > $w)] | length' "$rate_file" 2>/dev/null) || count=0
  else
    count=0
  fi

  (( count >= limit )) && return 1

  # Record this request
  local updated
  if [[ -f "$rate_file" ]]; then
    updated=$(jq --argjson w "$window" --argjson n "$now" '[.[] | select(. > $w)] + [$n]' "$rate_file" 2>/dev/null) || updated="[$now]"
  else
    updated="[$now]"
  fi
  printf '%s' "$updated" > "$rate_file"
  return 0
}

# Check message dedup via cursor
# Returns 0 if new message, 1 if already processed
dedup_message() {
  local channel="${1:?channel required}"
  local msg_id="${2:?msg_id required}"
  local cursor_file="${MARKER_DIR:-/tmp/cc-monitor}/cursor-${channel}.json"
  local last_id

  [[ -f "$cursor_file" ]] && last_id=$(jq -r '.last_id // ""' "$cursor_file" 2>/dev/null) || last_id=""
  [[ "$last_id" == "$msg_id" ]] && return 1

  printf '{"last_id":"%s"}' "$msg_id" > "$cursor_file"
  return 0
}

# Execute a validated command on target session
execute_command() {
  local session="${1:?session required}"
  local cmd="${2:?command required}"
  local pane_id

  case "$cmd" in
    继续|continue)
      # Find pane_id for session
      pane_id=$(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null | head -1)
      [[ -z "$pane_id" ]] && return 1
      tmux send-keys -t "$pane_id" -l -- "继续" 2>/dev/null || true
      sleep 0.3
      tmux send-keys -t "$pane_id" Enter 2>/dev/null || true
      ;;
    停止|stop)
      pane_id=$(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null | head -1)
      [[ -z "$pane_id" ]] && return 1
      tmux send-keys -t "$pane_id" Escape 2>/dev/null || true
      ;;
    状态|status)
      local summary=""
      while read -r s p; do
        local text
        text=$(capture_pane "$p" | tail -5 | head -3)
        summary="${summary}[${s}] ${text}\n"
      done < <(list_claude_panes)
      notify_user "**[Monitor]** Session 状态:\n${summary}" "所有 session 状态"
      ;;
  esac
}

# Main daemon loop
remote_input_loop() {
  local poll_interval
  poll_interval=$(config_get "input:wechat:poll_interval" "30")

  local plugin enabled channel_name
  for plugin in "$SCRIPT_DIR/inputs/"*.sh; do
    [[ -f "$plugin" ]] || continue
    channel_name=$(basename "$plugin" .sh)
    [[ "$channel_name" == _* ]] && continue

    enabled=$(config_get "input:${channel_name}:enabled" "false")
    [[ "$enabled" != "true" ]] && continue

    while true; do
      # shellcheck source=/dev/null
      source "$plugin"
      local messages
      # Timeout input_poll to prevent blocking (30s max)
      messages=$(timeout 30 input_poll 2>/dev/null) || { sleep "$poll_interval"; continue; }

      local count
      count=$(echo "$messages" | jq 'length' 2>/dev/null) || count=0
      (( count == 0 )) && { sleep "$poll_interval"; continue; }

      local i msg_id sender_id chat_id text timestamp channel
      for ((i = 0; i < count; i++)); do
        msg_id=$(echo "$messages" | jq -r ".[$i].id // empty" 2>/dev/null)
        sender_id=$(echo "$messages" | jq -r ".[$i].sender_id // empty" 2>/dev/null)
        chat_id=$(echo "$messages" | jq -r ".[$i].chat_id // empty" 2>/dev/null)
        text=$(echo "$messages" | jq -r ".[$i].text // empty" 2>/dev/null)
        timestamp=$(echo "$messages" | jq -r ".[$i].timestamp // 0" 2>/dev/null)
        channel=$(echo "$messages" | jq -r ".[$i].channel // \"$channel_name\"" 2>/dev/null)

        # Dedup
        dedup_message "$channel" "$msg_id" || continue

        # Sender whitelist
        is_sender_allowed "$sender_id" "$chat_id" || continue

        # Parse command
        local PARSED_SESSION PARSED_COMMAND
        parse_command "$text" || continue

        # Command whitelist
        is_command_allowed "$PARSED_COMMAND" || continue

        # Rate limit
        [[ -n "$PARSED_SESSION" ]] && check_rate_limit "$PARSED_SESSION" || true

        # Execute
        execute_command "$PARSED_SESSION" "$PARSED_COMMAND"
      done

      sleep "$poll_interval"
    done
  done
}

# Entry point for remote-input command
remote_input_main() {
  local pidfile
  pidfile=$(config_get "remote-input:pidfile" "/tmp/cc-monitor/remote-input.pid")

  case "${2:-}" in
    --stop)
      if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile")
        kill "$pid" 2>/dev/null && echo "Stopped remote-input (pid $pid)" || echo "Process not found"
        rm -f "$pidfile"
      else
        echo "Not running"
      fi
      return 0
      ;;
  esac

  # Check single instance
  if [[ -f "$pidfile" ]]; then
    local old_pid
    old_pid=$(cat "$pidfile")
    if kill -0 "$old_pid" 2>/dev/null; then
      echo "Already running (pid $old_pid)"
      return 0
    fi
    rm -f "$pidfile"
  fi

  echo $$ > "$pidfile"
  mkdir -p "$(dirname "$pidfile")"

  remote_input_loop
}
