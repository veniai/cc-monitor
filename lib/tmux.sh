#!/usr/bin/env bash
# tmux utility functions for cc-monitor

[[ -n "${_TMUX_LOADED:-}" ]] && return 0
_TMUX_LOADED=1

# Find the tmux session name for the current pane
find_tmux_session() {
  if [[ -z "${TMUX_PANE:-}" ]]; then
    return 1
  fi
  tmux list-panes -a -F '#{session_name} #{pane_id}' 2>/dev/null \
    | awk -v pane="$TMUX_PANE" '$2 == pane { print $1; exit }'
}

# Send recovery key sequence to a stuck Claude Code session
recover_session() {
  local target="${1:?target pane/session required}"
  local message="${2:-临时中断，重试刚才的步骤，不要跳过或变通}"
  tmux send-keys -t "$target" -X cancel 2>/dev/null || true
  sleep 0.3
  tmux send-keys -t "$target" Escape 2>/dev/null || true
  sleep 0.5
  tmux set-buffer "$message" 2>/dev/null || true
  tmux paste-buffer -t "$target" 2>/dev/null || true
  sleep 0.5
  tmux send-keys -t "$target" Enter 2>/dev/null || true
}

# Answer an AskUserQuestion prompt in the terminal
# Usage: answer_question <pane> <response_text>
answer_question() {
  local pane="${1:?pane required}"
  local text="${2:?response text required}"
  # Dismiss the question UI
  tmux send-keys -t "$pane" Escape 2>/dev/null || true
  sleep 0.5
  # Paste response as a new user message
  tmux set-buffer "$text" 2>/dev/null || true
  tmux paste-buffer -t "$pane" 2>/dev/null || true
  sleep 0.3
  tmux send-keys -t "$pane" Enter 2>/dev/null || true
}

# Capture visible screen content of a pane (no scrollback)
capture_pane() {
  local pane_id="${1:?pane_id required}"
  shift
  tmux capture-pane -t "$pane_id" -p "$@" 2>/dev/null
}

# Check if a pane is running claude
is_claude_alive() {
  local pane_id="${1:?pane_id required}"
  local pane_cmd
  pane_cmd=$(tmux list-panes -t "$pane_id" -F '#{pane_current_command}' 2>/dev/null)
  [[ "$pane_cmd" == "claude" ]]
}

# List all panes running claude, output: session_name pane_id
list_claude_panes() {
  tmux list-panes -a -F '#{session_name} #{pane_id} #{pane_current_command}' 2>/dev/null \
    | awk '$3 == "claude" { print $1, $2 }'
}
