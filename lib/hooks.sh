#!/usr/bin/env bash
# CC hooks handler for cc-monitor

[[ -n "${_HOOKS_LOADED:-}" ]] && return 0
_HOOKS_LOADED=1

# Debug dump: log hook payload for troubleshooting
dump_debug() {
  local debug_dir="${MARKER_DIR:-/tmp/cc-monitor}/debug"
  mkdir -p "$debug_dir"
  local event="${HOOK_EVENT:-unknown}"
  printf '%s' "$HOOK_INPUT" | jq -c '{
    hook_event_name,
    reason,
    error,
    stop_reason,
    tool_name,
    tool_input_keys: (.tool_input // {} | keys?),
    last_msg_len: (.last_assistant_message // "" | length)
  }' >"$debug_dir/${event}-$(date +%s).json" 2>/dev/null || true
  # Keep only last 20 debug files
  ls -t "$debug_dir"/*.json 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true
}

is_permanent_error() {
  printf '%s' "$1" | grep -qiE '\bauthentication\b|\bunauthorized\b|\bforbidden\b|\binvalid.api.key\b|\bquota.exceeded\b|\bbilling\b|\binvalid_request\b|\bpayment\b'
}

is_safe_tool() {
  local tool="$1"
  case "$tool" in
    Read|Glob|Grep|Agent|TaskCreate|TaskGet|TaskList|TaskUpdate|NotebookEdit|ListMcpResourcesTool|ReadMcpResourceTool|mcp__plugin_context7_*)
      return 0 ;;
    *) return 1 ;;
  esac
}

truncate_str() {
  local str="$1" max="$2"
  if (( ${#str} > max )); then
    printf '%s...' "${str:0:max}"
  else
    printf '%s' "$str"
  fi
}

get_tool_detail() {
  local tool="$1" input="$2"
  [[ -z "$input" || "$input" == "null" ]] && return 0
  case "$tool" in
    Edit|Write)
      local file_path
      file_path=$(printf '%s' "$input" | jq -r '.file_path // empty' 2>/dev/null)
      [[ -n "$file_path" ]] && echo "文件: $file_path" ;;
    Bash)
      local command
      command=$(printf '%s' "$input" | jq -r '.command // empty' 2>/dev/null)
      [[ -n "$command" ]] && echo "命令: $(truncate_str "$command" 200)" ;;
    Agent)
      local desc
      desc=$(printf '%s' "$input" | jq -r '.description // empty' 2>/dev/null)
      [[ -n "$desc" ]] && echo "任务: $(truncate_str "$desc" 200)" ;;
    AskUserQuestion)
      local question options
      question=$(printf '%s' "$input" | jq -r '.questions[0].question // empty' 2>/dev/null)
      [[ -n "$question" ]] && echo "问题: $(truncate_str "$question" 200)"
      options=$(printf '%s' "$input" | jq -r '.questions[0].options[]? | "\(.label): \(.description // "")"' 2>/dev/null)
      [[ -n "$options" ]] && echo "$options" | head -8 ;;
    *)
      local first
      first=$(printf '%s' "$input" | jq -r 'to_entries[0] | "\(.key): \(.value | tostring)"' 2>/dev/null)
      [[ -n "$first" && "$first" != "null" ]] && echo "$(truncate_str "$first" 200)" ;;
  esac
}

handle_stop() {
  local summary="${HOOK_LAST_MSG:-(任务已完成，无输出摘要)}"
  summary="$(truncate_str "$summary" 5000)"
  local msg
  printf -v msg '**[Monitor]** %s 任务完成:\n\n%s' "$TMUX_SESSION" "$summary"
  notify_user "$msg" "${TMUX_SESSION} ✓ 完成"
  marker_update "$TMUX_SESSION" '.stop_seen = true | del(.quota_resets_at)' 2>/dev/null || true
}

handle_stop_failure() {
  if is_permanent_error "$HOOK_REASON"; then
    local msg
    printf -v msg '**[Monitor]** %s 不可恢复的错误:\n%s' "$TMUX_SESSION" "$HOOK_REASON"
    notify_user "$msg" "${TMUX_SESSION} ✗ 错误: $(truncate_str "$HOOK_REASON" 50)"
    marker_cleanup "$TMUX_SESSION"
    return 0
  fi

  # --- Quota limit detection: suppress retry until reset time ---
  # Skip if already notified (prevents duplicate notifications from repeated StopFailure)
  local existing_quota
  existing_quota=$(marker_read "$TMUX_SESSION" "quota_resets_at")
  if [[ -n "$existing_quota" && "$existing_quota" != "null" && "$existing_quota" != "" ]]; then
    return 0
  fi

  local pane_text reset_match reset_ts
  pane_text=$(capture_pane "$TMUX_PANE")
  reset_match=$(echo "$pane_text" | grep -oP '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?= 重置)' | tail -1)
  if [[ -n "$reset_match" ]]; then
    reset_ts=$(date -d "$reset_match" +%s 2>/dev/null) || reset_ts=0
    if (( reset_ts > 0 )); then
      marker_update "$TMUX_SESSION" ".quota_resets_at = $reset_ts | .auto_resume_count = 0 | .screen_md5_stable_count = 0"
      local reset_display
      reset_display=$(date -d "@$reset_ts" '+%Y-%m-%d %H:%M:%S')
      local msg
      printf -v msg '**[Monitor]** %s 5小时限额已满，%s 后自动恢复（最晚约5分钟内）' "$TMUX_SESSION" "$reset_display"
      notify_user "$msg" "${TMUX_SESSION} ⏸ 限额满，${reset_display} 恢复"
      return 0
    fi
  fi

  if ! is_claude_alive "$TMUX_PANE"; then
    notify_user \
      "**[Monitor]** ${TMUX_SESSION} 进程已退出，无法自动恢复" \
      "${TMUX_SESSION} ✗ 进程已退出"
    marker_cleanup "$TMUX_SESSION"
    return 0
  fi

  local count last_retry now backoff
  count=$(marker_read "$TMUX_SESSION" "auto_resume_count") || count=0
  last_retry=$(marker_read "$TMUX_SESSION" "last_retry_at") || last_retry=0
  now=$(date +%s)
  (( now - last_retry > 600 )) && count=0

  if (( count >= 5 )); then
    local msg
    printf -v msg '**[Monitor]** %s 连续%s次 API 错误，请手动检查\n原因: %s' "$TMUX_SESSION" "$count" "$HOOK_REASON"
    notify_user "$msg" "${TMUX_SESSION} ⚠ API错误x${count}: $(truncate_str "$HOOK_REASON" 50)"
    marker_cleanup "$TMUX_SESSION"
    return 0
  fi

  backoff=$(( (count + 1) * 10 ))
  marker_update "$TMUX_SESSION" ".last_retry_at = $now | .auto_resume_count = ($count + 1)"
  sleep "$backoff"

  local before after
  before=$(capture_pane "$TMUX_PANE" -S -5 | md5sum | awk '{print $1}')
  recover_session "$TMUX_PANE"
  sleep 2
  after=$(capture_pane "$TMUX_PANE" -S -5 | md5sum | awk '{print $1}')

  if [[ "$before" == "$after" ]]; then
    notify_user \
      "**[Monitor]** ${TMUX_SESSION} 自动恢复发送失败，请手动检查" \
      "${TMUX_SESSION} ✗ 发送失败"
    marker_cleanup "$TMUX_SESSION"
  fi
}

handle_permission_request() {
  if is_safe_tool "$HOOK_TOOL_NAME"; then
    printf '%s\n' '{"decision":"approve"}'
    return 0
  fi

  # AskUserQuestion: approve immediately, handle response in background
  if [[ "$HOOK_TOOL_NAME" == "AskUserQuestion" ]]; then
    handle_ask_user_question
    return $?
  fi

  # All other tools: auto-approve + notify + press Enter to dismiss UI
  local detail msg short
  detail=$(get_tool_detail "$HOOK_TOOL_NAME" "$HOOK_TOOL_INPUT")
  printf -v msg '**[Monitor]** %s 自动批准 %s' "$TMUX_SESSION" "$HOOK_TOOL_NAME"
  [[ -n "$detail" ]] && printf -v msg '%s\n%s' "$msg" "$detail"
  short="${TMUX_SESSION} ✅ ${HOOK_TOOL_NAME}"
  [[ -n "$detail" ]] && short="${short} $(truncate_str "$detail" 50)"
  notify_user "$msg" "$short"

  printf '%s\n' '{"decision":"approve"}'

  # Dismiss any confirmation UI (overwrite dialog etc.) that appears after approve
  ( sleep 2 && tmux send-keys -t "$TMUX_PANE" Enter 2>/dev/null ) & disown
}

# Handle AskUserQuestion: approve immediately, then manage response via background process
handle_ask_user_question() {
  # Extract all questions up front
  local questions_json question_count
  questions_json=$(printf '%s' "$HOOK_TOOL_INPUT" | jq -c '[.questions[]? | {question: .question, options: [.options[]? | .label]}]' 2>/dev/null)
  question_count=$(printf '%s' "$questions_json" | jq 'length' 2>/dev/null)
  [[ -z "$question_count" || "$question_count" == "null" || "$question_count" == "0" ]] && question_count=1

  # Kill any stale background process for this session
  local pid_file="${MARKER_DIR:-/tmp/cc-monitor}/${TMUX_SESSION}.pid"
  if [[ -f "$pid_file" ]]; then
    local old_pid
    old_pid=$(cat "$pid_file" 2>/dev/null)
    [[ -n "$old_pid" ]] && kill "$old_pid" 2>/dev/null || true
    rm -f "$pid_file"
  fi

  (
    local session="$TMUX_SESSION"
    local pane="$TMUX_PANE"
    local marker_dir="${MARKER_DIR:-/tmp/cc-monitor}"
    local marker_file="${marker_dir}/${session}.json"
    local questions="$questions_json"
    local count="$question_count"
    local _dbg="${marker_dir}/debug/aq-bg-$(date +%s).log"

    echo $$ > "${marker_dir}/${session}.pid"
    trap 'rm -f "${marker_dir}/${session}.pid"' EXIT

    echo "[$(date)] START session=$session count=$count pane=$pane" > "$_dbg"
    echo "[$(date)] questions=$questions" >> "$_dbg"

    for ((i=0; i<count; i++)); do
      local q_text q_options_block
      q_text=$(printf '%s' "$questions" | jq -r ".[$i].question // empty" 2>/dev/null)
      q_options_block=$(printf '%s' "$questions" | jq -r "
        .[$i].options // [] | to_entries[] |
        \" \(.key + 1). \(.value)\"
      " 2>/dev/null)

      # 1. Write pending_response FIRST (before notification, to avoid race)
      local now
      now=$(date +%s)
      marker_update "$session" ".pending_response = {created_at: $now, response: null}"
      echo "[$(date)] Q$((i+1)): pending_response written" >> "$_dbg"

      # 2. Send notification for this question
      local q_num=$((i + 1)) msg short
      if (( count > 1 )); then
        printf -v msg '**[Monitor]** %s 提问 (%d/%d):\n\n%s' "$session" "$q_num" "$count" "$(truncate_str "$q_text" 300)"
      else
        printf -v msg '**[Monitor]** %s 提问:\n\n%s' "$session" "$(truncate_str "$q_text" 300)"
      fi
      [[ -n "$q_options_block" ]] && printf -v msg '%s\n%s' "$msg" "$q_options_block"
      printf -v msg '%s\n\n%s' "$msg" "回复任意内容作答"
      short="${session} ❓ $(truncate_str "$q_text" 60)"
      echo "[$(date)] Q$((i+1)): notify_user starting" >> "$_dbg"
      notify_user "$msg" "$short"
      echo "[$(date)] Q$((i+1)): notify_user done" >> "$_dbg"

      # 3. Immediately select "Type something" — cursor enters text input
      #    This protects against bot forwarding to tmux: text goes into input, not ignored
      local pane_snapshot type_key
      sleep 2  # Wait for UI to fully render
      pane_snapshot=$(tmux capture-pane -t "$pane" -p -S -20 2>/dev/null)
      if echo "$pane_snapshot" | grep -q "Type something"; then
        type_key=$(echo "$pane_snapshot" | grep -oP '\d+(?=\. Type something)' | tail -1)
        [[ -z "$type_key" ]] && type_key=4
        tmux send-keys -t "$pane" "$type_key" 2>/dev/null || true
        sleep 1
        echo "[$(date)] Q$((i+1)): selected Type something (key=$type_key)" >> "$_dbg"
      else
        echo "[$(date)] Q$((i+1)): UI already gone before Type something" >> "$_dbg"
        marker_update "$session" "del(.pending_response)"
        continue
      fi

      # 4. Poll for IM response; if text arrives via tmux, it goes into the input field
      local response=""
      while true; do
        sleep 5
        response=$(jq -r '.pending_response.response // ""' "$marker_file" 2>/dev/null)
        echo "[$(date)] Q$((i+1)): poll response='$response'" >> "$_dbg"
        if [[ -n "$response" && "$response" != "null" && "$response" != "" ]]; then
          echo "[$(date)] Q$((i+1)): got response='$response'" >> "$_dbg"
          break
        fi
        # Check if text input is still active
        local pane_check
        pane_check=$(tmux capture-pane -t "$pane" -p -S -20 2>/dev/null)
        if ! echo "$pane_check" | grep -qE "Type something|Enter to select"; then
          echo "[$(date)] Q$((i+1)): UI gone, pane content:" >> "$_dbg"
          echo "$pane_check" | tail -10 >> "$_dbg"
          marker_update "$session" "del(.pending_response)"
          continue 2
        fi
      done

      # 5. Paste response into text input and submit
      tmux set-buffer "$response" 2>/dev/null || true
      tmux paste-buffer -t "$pane" 2>/dev/null || true
      sleep 2
      tmux send-keys -t "$pane" Enter 2>/dev/null || true

      marker_update "$session" "del(.pending_response)"

      # Wait for UI to advance to next question or Submit
      if (( i < count - 1 )); then
        sleep 3
      else
        sleep 1
      fi
    done

    # Submit — only if Submit button is visible
    local submit_pane
    submit_pane=$(tmux capture-pane -t "$pane" -p -S -20 2>/dev/null)
    if echo "$submit_pane" | grep -q "Submit"; then
      tmux send-keys -t "$pane" Enter 2>/dev/null || true
    fi
    rm -f "${marker_dir}/${session}.pid"
  ) & disown

  printf '%s\n' '{"decision":"approve"}'
}

handle_session_end() {
  marker_cleanup "$TMUX_SESSION"
}

# Codex CLI stop handler — Codex expects valid JSON on stdout
handle_codex_stop() {
  local input msg pane_cmd
  input=$(cat)

  TMUX_SESSION=$(find_tmux_session) || { printf '%s\n' '{}'; return 0; }
  export TMUX_SESSION
  pane_cmd=$(tmux list-panes -t "$TMUX_PANE" -F '#{pane_current_command}' 2>/dev/null)
  # Skip if running inside Claude Code (not a standalone Codex session)
  [[ "$pane_cmd" == "claude" ]] && { printf '%s\n' '{}'; return 0; }

  msg=$(printf '%s' "$input" | jq -r '.last_assistant_message // empty')
  [[ -z "$msg" ]] && msg="(Codex 任务完成，无输出摘要)"
  notify_user \
    "**[Codex Monitor]** ${TMUX_SESSION} 任务完成:\n\n$(truncate_str "$msg" 5000)" \
    "${TMUX_SESSION} ✓ Codex完成"

  printf '%s\n' '{}'
}

# Main hook entry point — reads JSON from stdin
handle_hook_main() {
  local input
  input=$(cat)

  local event last_msg reason tool_name tool_input
  event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty')
  last_msg=$(printf '%s' "$input" | jq -r '.last_assistant_message // empty')
  reason=$(printf '%s' "$input" | jq -r '.reason // .error // .stop_reason // empty')
  tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  tool_input=$(printf '%s' "$input" | jq -c '.tool_input // empty')

  # Export for sub-functions
  HOOK_INPUT="$input"
  HOOK_EVENT="$event"
  HOOK_LAST_MSG="$last_msg"
  HOOK_REASON="$reason"
  HOOK_TOOL_NAME="$tool_name"
  HOOK_TOOL_INPUT="$tool_input"

  dump_debug

  TMUX_SESSION=$(find_tmux_session) || exit 0
  [[ "${DEBUG_MODE:-false}" == "true" ]] && echo "[cc-monitor] mode=${CC_MODE:-unknown} session=$TMUX_SESSION event=$event" >&2

  marker_ensure "$TMUX_SESSION"

  case "$event" in
    StopFailure)       handle_stop_failure ;;
    PermissionRequest) handle_permission_request ;;
    Stop)              handle_stop ;;
    SessionEnd)        handle_session_end ;;
  esac
}

