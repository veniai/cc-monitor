#!/usr/bin/env bash
# cc-monitor — Claude Code remote monitoring and input tool
# Usage: cc-monitor.sh {hook|watchdog [--dry-run]|remote-input [--stop]}

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

case "${1:-help}" in
  hook)
    handle_hook_main
    ;;
  watchdog)
    DRY_RUN=false
    [[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true
    handle_watchdog
    ;;
  remote-input)
    source "$SCRIPT_DIR/lib/remote-input.sh"
    remote_input_main "$@"
    ;;
  help|*)
    cat <<'USAGE'
cc-monitor — Claude Code remote monitoring and input tool

Usage: cc-monitor.sh <command> [options]

Commands:
  hook                CC hooks entry (reads JSON from stdin)
  watchdog [--dry-run]  Check for stuck sessions
  remote-input [--stop]  Start/stop remote input daemon
  help                Show this help

Setup:
  1. Copy config.example.conf to ~/.config/cc-monitor/config.conf
  2. Edit config.conf with your channel credentials
  3. Run: ./install.sh --interactive
USAGE
    ;;
esac
