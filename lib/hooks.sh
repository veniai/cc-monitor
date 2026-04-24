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
  summary="$(truncate_str "$summary" 3000)"
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
  (( now - last_retry > 300 )) && count=0

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

  local detail msg short
  detail=$(get_tool_detail "$HOOK_TOOL_NAME" "$HOOK_TOOL_INPUT")
  printf -v msg '**[Monitor]** %s 请求执行 %s' "$TMUX_SESSION" "$HOOK_TOOL_NAME"
  [[ -n "$detail" ]] && printf -v msg '%s\n%s' "$msg" "$detail"

  local auto_approve
  auto_approve=$(config_get "monitor:auto_approve_permissions" "true")

  if [[ "$auto_approve" == "true" ]]; then
    local timeout_secs
    timeout_secs=$(config_get "monitor:auto_approve_timeout" "300")
    printf -v msg '%s\n%s' "$msg" "${timeout_secs}秒内未处理将自动批准"
    short="${TMUX_SESSION} ⚠ 权限: ${HOOK_TOOL_NAME}"
    [[ -n "$detail" ]] && short="${short} $(truncate_str "$detail" 50)"
    notify_user "$msg" "$short"
    sleep "$timeout_secs"
    printf '%s\n' '{"decision":"approve"}'
  else
    printf -v msg '%s\n%s' "$msg" "请手动处理此权限请求"
    short="${TMUX_SESSION} ⚠ 权限: ${HOOK_TOOL_NAME}"
    [[ -n "$detail" ]] && short="${short} $(truncate_str "$detail" 50)"
    notify_user "$msg" "$short"
    printf '%s\n' '{"decision":"deny"}'
  fi
}

handle_session_end() {
  marker_cleanup "$TMUX_SESSION"
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

