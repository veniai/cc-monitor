#!/usr/bin/env bash
# cc-monitor v1.1.0 — Claude Code remote monitoring tool
# Usage: cc-monitor.sh {hook|watchdog [--dry-run]}

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source lib modules
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/tmux.sh"
source "$SCRIPT_DIR/lib/marker.sh"
source "$SCRIPT_DIR/lib/notify.sh"
source "$SCRIPT_DIR/lib/hooks.sh"
source "$SCRIPT_DIR/lib/watchdog.sh"

config_load
config_validate

# Health check function
run_health_check() {
  echo "cc-monitor health check"
  echo "---"
  # Config
  if [[ -f "${CONFIG_FILE:-}" ]]; then
    echo "[OK] Config: $CONFIG_FILE"
  else
    echo "[FAIL] Config not found (checked: ${CONFIG_FILE:-unset})"
  fi
  # tmux
  if command -v tmux &>/dev/null && tmux list-sessions &>/dev/null; then
    local cc_count
    cc_count=$(tmux list-panes -a -F '#{pane_current_command}' 2>/dev/null | grep -c "claude" || echo 0)
    echo "[OK] tmux: $(tmux list-sessions 2>/dev/null | wc -l) sessions, $cc_count Claude Code panes"
  else
    echo "[WARN] tmux not running or not installed"
  fi
  # Channels
  local plugin channel_name enabled any_enabled="false"
  for plugin in "$SCRIPT_DIR/channels/"*.sh; do
    [[ -f "$plugin" ]] || continue
    channel_name=$(basename "$plugin" .sh)
    [[ "$channel_name" == _* ]] && continue
    enabled=$(config_get "channel:${channel_name}:enabled" "false")
    if [[ "$enabled" == "true" ]]; then
      echo "[OK] Channel: $channel_name (enabled)"
      any_enabled="true"
    fi
  done
  if [[ "$any_enabled" != "true" ]]; then
    echo "[WARN] No notification channels enabled"
  fi
  # Hooks
  if [[ -f "$HOME/.claude/settings.json" ]]; then
    local hook_count
    hook_count=$(jq '.hooks | to_entries | map(select(.key == "Stop" or .key == "StopFailure" or .key == "PermissionRequest" or .key == "SessionEnd")) | length' "$HOME/.claude/settings.json" 2>/dev/null || echo 0)
    if (( hook_count >= 4 )); then
      echo "[OK] Hooks: $hook_count events registered"
    else
      echo "[WARN] Hooks: only $hook_count/4 events registered (run install.sh)"
    fi
  else
    echo "[WARN] No Claude Code settings.json found"
  fi
}

case "${1:-help}" in
  version|--version|-V)
    echo "cc-monitor v1.1.0"
    ;;
  hook)
    handle_hook_main
    ;;
  codex)
    handle_codex_stop
    ;;
  watchdog)
    DRY_RUN=false
    [[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true
    handle_watchdog
    ;;
  health)
    run_health_check
    ;;
  help|*)
    cat <<'USAGE'
cc-monitor — Claude Code remote monitoring tool

Usage: cc-monitor.sh <command> [options]

Commands:
  hook                CC hooks entry (reads JSON from stdin)
  codex               Codex CLI stop handler (reads JSON from stdin)
  watchdog [--dry-run]  Check for stuck sessions
  health              Check installation status
  version             Show version
  help                Show this help

Setup:
  1. Copy config.example.conf to ~/.config/cc-monitor/config.conf
  2. Edit config.conf — choose mode (direct or openclaw)
  3. Run: ./install.sh --interactive

Remote input (bidirectional IM):
  Use OpenClaw (https://github.com/veniai/openclaw)
USAGE
    ;;
esac
