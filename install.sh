#!/usr/bin/env bash
# cc-monitor installer — interactive/non-interactive setup, hooks, cron, uninstall
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/cc-monitor"
SETTINGS_FILE="$HOME/.claude/settings.json"
CRON_MARKER="# cc-monitor-entry"
HOOK_SCRIPT="$SCRIPT_DIR/cc-monitor.sh"

# ---------------------------------------------------------------------------
# Colors (disabled when not a tty)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi

info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die()   { error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# usage / help
# ---------------------------------------------------------------------------
show_help() {
  cat <<'HELP'
cc-monitor installer

Usage:
  install.sh [OPTIONS]

Options:
  --interactive            Prompt for each configuration value
  --channel CHANNEL        Notification channel to enable (wechat|dingtalk|feishu)
  --enable-watchdog        Register watchdog cron job (every 5 min)
  --enable-remote-input    Register remote-input cron job (every minute)
  --uninstall              Remove hooks, cron entries, daemon, and optionally config
  --help                   Show this help

Non-interactive example:
  install.sh --channel wechat --enable-watchdog --enable-remote-input

Interactive example:
  install.sh --interactive
HELP
}

# ---------------------------------------------------------------------------
# detect_platform
# ---------------------------------------------------------------------------
detect_platform() {
  local kernel
  kernel="$(uname -s)"
  if [[ "$kernel" != "Linux" ]]; then
    if [[ "$kernel" == *"MING"* || "$kernel" == *"MSYS"* || "$kernel" == *"CYGWIN"* ]]; then
      die "Native Windows is not supported. Please use WSL or Linux."
    fi
    warn "Unsupported platform: $kernel — continuing anyway"
  fi

  local release
  release="$(uname -r 2>/dev/null || true)"
  if [[ "$release" == *"microsoft"* || "$release" == *"Microsoft"* || "$release" == *"WSL"* ]]; then
    info "Detected WSL environment"
  fi
  info "Platform: $kernel ($release)"
}

# ---------------------------------------------------------------------------
# check_dependencies
# ---------------------------------------------------------------------------
check_dependencies() {
  local required=(bash tmux jq grep python3)
  local missing=()

  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} )); then
    die "Missing required commands: ${missing[*]}. Please install them first."
  fi
  info "All required dependencies satisfied"

  # Optional: openclaw (needed for wechat channel)
  if ! command -v openclaw &>/dev/null; then
    warn "Optional: 'openclaw' not found — only needed for wechat channel"
  fi
}

# ---------------------------------------------------------------------------
# generate_config
# ---------------------------------------------------------------------------
generate_config() {
  local interactive="${1:-false}"

  mkdir -p "$CONFIG_DIR"

  if [[ ! -f "$SCRIPT_DIR/config.example.conf" ]]; then
    die "config.example.conf not found in $SCRIPT_DIR"
  fi

  if [[ -f "$CONFIG_DIR/config.conf" ]]; then
    if [[ "$interactive" == "true" ]]; then
      read -rp "Config already exists at $CONFIG_DIR/config.conf. Overwrite? [y/N] " answer
      [[ "${answer,,}" != "y" ]] && { info "Keeping existing config"; return 0; }
    else
      info "Config already exists, keeping it (use --interactive to reconfigure)"
      return 0
    fi
  fi

  cp "$SCRIPT_DIR/config.example.conf" "$CONFIG_DIR/config.conf"
  chmod 0600 "$CONFIG_DIR/config.conf"
  info "Config created at $CONFIG_DIR/config.conf"

  if [[ "$interactive" == "true" ]]; then
    prompt_channel_config
  fi

  info "Config permissions set to 0600"
}

prompt_channel_config() {
  local conf="$CONFIG_DIR/config.conf"

  echo ""
  printf "${BOLD}--- Channel Configuration ---${NC}\n"

  # Wechat
  read -rp "Enable WeChat channel? [y/N] " ans
  if [[ "${ans,,}" == "y" ]]; then
    set_config_value "$conf" "enabled" "true" "channel:wechat"
    read -rp "  WeChat account: " account
    set_config_value "$conf" "account" "$account" "channel:wechat"
    read -rp "  WeChat target: " target
    set_config_value "$conf" "target" "$target" "channel:wechat"
  fi

  # DingTalk
  read -rp "Enable DingTalk channel? [y/N] " ans
  if [[ "${ans,,}" == "y" ]]; then
    set_config_value "$conf" "enabled" "true" "channel:dingtalk"
    read -rp "  DingTalk webhook URL: " webhook
    set_config_value "$conf" "webhook" "$webhook" "channel:dingtalk"
    read -rp "  DingTalk secret (optional): " secret
    set_config_value "$conf" "secret" "$secret" "channel:dingtalk"
  fi

  # Feishu
  read -rp "Enable Feishu channel? [y/N] " ans
  if [[ "${ans,,}" == "y" ]]; then
    set_config_value "$conf" "enabled" "true" "channel:feishu"
    read -rp "  Feishu webhook URL: " webhook
    set_config_value "$conf" "webhook" "$webhook" "channel:feishu"
  fi

  # Wechat input
  read -rp "Enable WeChat remote input? [y/N] " ans
  if [[ "${ans,,}" == "y" ]]; then
    set_config_value "$conf" "enabled" "true" "input:wechat"
    read -rp "  Allowed senders (comma-separated): " senders
    set_config_value "$conf" "allowed_senders" "$senders" "input:wechat"
    read -rp "  Allowed chats (comma-separated): " chats
    set_config_value "$conf" "allowed_chats" "$chats" "input:wechat"
  fi
}

# Set a value in the ini-style config file under a given section
# Usage: set_config_value <file> <key> <value> <section>
set_config_value() {
  local file="$1" key="$2" value="$3" section="$4"
  local in_section=false
  local tmp
  tmp="$(mktemp)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "[$section]" ]]; then
      in_section=true
    elif [[ "$line" == "["* ]]; then
      in_section=false
    fi

    if $in_section && [[ "$line" == "$key="* ]]; then
      echo "$key=$value"
    else
      echo "$line"
    fi
  done < "$file" > "$tmp"
  mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# register_hooks
# ---------------------------------------------------------------------------
register_hooks() {
  local hook_command="bash $HOOK_SCRIPT hook"
  local settings="$SETTINGS_FILE"

  if [[ ! -f "$settings" ]]; then
    mkdir -p "$(dirname "$settings")"
    echo '{}' > "$settings"
  fi

  local hook_events=("Stop" "StopFailure" "PermissionRequest" "SessionEnd")
  local changed=false

  for event in "${hook_events[@]}"; do
    # Check if hook already registered for this event with our script
    local existing
    existing="$(jq -r --arg event "$event" --arg cmd "$hook_command" '
      .hooks[$event] // [] | map(select(.hooks[]?.command == $cmd)) | length
    ' "$settings" 2>/dev/null || echo "0")"

    if [[ "$existing" != "0" ]]; then
      info "Hook for $event already registered — skipping"
      continue
    fi

    # Build the hook entry
    local entry
    if [[ "$event" == "SessionEnd" ]]; then
      entry="$(jq -n --arg cmd "$hook_command" '{
        matcher: "",
        hooks: [{ type: "command", command: $cmd, timeout: 5000 }]
      }')"
    else
      entry="$(jq -n --arg cmd "$hook_command" '{
        matcher: "",
        hooks: [{ type: "command", command: $cmd }]
      }')"
    fi

    # Add entry to the event array
    local tmp
    tmp="$(mktemp)"
    jq --arg event "$event" --argjson entry "$entry" '
      .hooks[$event] = (.hooks[$event] // []) + [$entry]
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"

    info "Registered hook for $event"
    changed=true
  done

  if $changed; then
    info "Hooks registered in $settings"
  fi
}

# ---------------------------------------------------------------------------
# register_cron
# ---------------------------------------------------------------------------
register_cron() {
  local enable_watchdog="${1:-false}"
  local enable_remote_input="${2:-false}"

  if ! $enable_watchdog && ! $enable_remote_input; then
    info "No cron jobs requested — skipping"
    return 0
  fi

  # Ensure crontab exists
  command -v crontab &>/dev/null || die "crontab command not found"

  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v "$CRON_MARKER" > "$tmp" || true

  if $enable_watchdog; then
    echo "LC_ALL=C.UTF-8 */5 * * * * cd $SCRIPT_DIR && bash watchdog-entry.sh  $CRON_MARKER watchdog" >> "$tmp"
    info "Watchdog cron registered (every 5 minutes)"
  fi

  if $enable_remote_input; then
    echo "LC_ALL=C.UTF-8 * * * * * cd $SCRIPT_DIR && bash remote-input-entry.sh  $CRON_MARKER remote-input" >> "$tmp"
    info "Remote-input cron registered (every minute)"
  fi

  crontab "$tmp"
  rm -f "$tmp"
  info "Cron jobs installed"
}

# ---------------------------------------------------------------------------
# preview_changes
# ---------------------------------------------------------------------------
preview_changes() {
  local enable_watchdog="${1:-false}"
  local enable_remote_input="${2:-false}"
  local hook_command="bash $HOOK_SCRIPT hook"

  printf "\n${BOLD}=== Changes Preview ===${NC}\n\n"

  printf "${BOLD}Hooks to register in $SETTINGS_FILE:${NC}\n"
  local hook_events=("Stop" "StopFailure" "PermissionRequest" "SessionEnd")
  for event in "${hook_events[@]}"; do
    local existing
    existing="$(jq -r --arg event "$event" --arg cmd "$hook_command" '
      .hooks[$event] // [] | map(select(.hooks[]?.command == $cmd)) | length
    ' "$SETTINGS_FILE" 2>/dev/null || echo "0")"
    if [[ "$existing" != "0" ]]; then
      printf "  [already exists] %s\n" "$event"
    else
      printf "  [new] %s -> %s\n" "$event" "$hook_command"
    fi
  done

  printf "\n${BOLD}Cron jobs to register:${NC}\n"
  if $enable_watchdog; then
    printf "  [new] */5 * * * * watchdog (every 5 min)\n"
  else
    printf "  [skip] watchdog\n"
  fi
  if $enable_remote_input; then
    printf "  [new] * * * * * remote-input (every minute)\n"
  else
    printf "  [skip] remote-input\n"
  fi

  printf "\n${BOLD}Config:${NC}\n"
  printf "  Location: $CONFIG_DIR/config.conf\n"

  printf "\n"
  read -rp "Proceed with these changes? [Y/n] " answer
  [[ "${answer,,}" == "n" ]] && die "Aborted by user"
}

# ---------------------------------------------------------------------------
# do_uninstall
# ---------------------------------------------------------------------------
do_uninstall() {
  printf "\n${BOLD}=== Uninstall cc-monitor ===${NC}\n\n"

  local hook_command="bash $HOOK_SCRIPT hook"

  # 1. Remove hooks from settings.json
  if [[ -f "$SETTINGS_FILE" ]]; then
    local hook_events=("Stop" "StopFailure" "PermissionRequest" "SessionEnd")
    for event in "${hook_events[@]}"; do
      local existing
      existing="$(jq -r --arg event "$event" --arg cmd "$hook_command" '
        .hooks[$event] // [] | map(select(.hooks[]?.command == $cmd)) | length
      ' "$SETTINGS_FILE" 2>/dev/null || echo "0")"
      if [[ "$existing" != "0" ]]; then
        local tmp
        tmp="$(mktemp)"
        jq --arg event "$event" --arg cmd "$hook_command" '
          .hooks[$event] = (.hooks[$event] // []) | map(
            .hooks = (.hooks // []) | map(select(.command != $cmd))
          ) | map(select((.hooks | length) > 0))
        ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
        info "Removed hook for $event"
      fi
    done

    # Clean up empty hook arrays
    local tmp
    tmp="$(mktemp)"
    jq '
      .hooks = (.hooks | to_entries | map(select(.value | length > 0)) | from_entries)
    ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
  fi

  # 2. Remove cron entries
  if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
    local tmp
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" > "$tmp"
    crontab "$tmp"
    rm -f "$tmp"
    info "Removed cc-monitor cron entries"
  fi

  # 3. Stop remote-input daemon
  local pidfile="/tmp/cc-monitor/remote-input.pid"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      info "Stopped remote-input daemon (PID $pid)"
    fi
    rm -f "$pidfile"
    info "Removed pidfile"
  fi

  # 4. Optionally remove config
  if [[ -d "$CONFIG_DIR" ]]; then
    read -rp "Remove config directory $CONFIG_DIR? [y/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
      rm -rf "$CONFIG_DIR"
      info "Removed config directory"
    else
      info "Config directory preserved"
    fi
  fi

  info "Uninstall complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local interactive=false
  local channel=""
  local enable_watchdog=false
  local enable_remote_input=false
  local do_uninstall_flag=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interactive)
        interactive=true
        shift
        ;;
      --channel)
        channel="${2:-}"
        [[ -z "$channel" ]] && die "--channel requires a value (wechat|dingtalk|feishu)"
        shift 2
        ;;
      --enable-watchdog)
        enable_watchdog=true
        shift
        ;;
      --enable-remote-input)
        enable_remote_input=true
        shift
        ;;
      --uninstall)
        do_uninstall_flag=true
        shift
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        die "Unknown option: $1. Use --help for usage."
        ;;
    esac
  done

  if $do_uninstall_flag; then
    do_uninstall
    exit 0
  fi

  # If channel specified but not interactive, enable it in config
  if [[ -n "$channel" ]] && [[ "$interactive" == "false" ]]; then
    mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$CONFIG_DIR/config.conf" ]]; then
      generate_config "$interactive"
    fi
    # Enable the specified channel
    local conf="$CONFIG_DIR/config.conf"
    if [[ -f "$conf" ]]; then
      set_config_value "$conf" "enabled" "true" "channel:$channel"
      info "Channel '$channel' enabled in config"
    fi
  fi

  info "cc-monitor installer"
  echo ""

  detect_platform
  check_dependencies
  generate_config "$interactive"

  # In interactive mode, ask about watchdog and remote-input
  if $interactive; then
    read -rp "Enable watchdog cron (checks every 5 min)? [y/N] " ans
    [[ "${ans,,}" == "y" ]] && enable_watchdog=true

    read -rp "Enable remote-input cron (checks every minute)? [y/N] " ans
    [[ "${ans,,}" == "y" ]] && enable_remote_input=true
  fi

  preview_changes "$enable_watchdog" "$enable_remote_input"

  register_hooks
  register_cron "$enable_watchdog" "$enable_remote_input"

  echo ""
  info "Installation complete!"
  info "Config: $CONFIG_DIR/config.conf"
  info "Hooks:  $SETTINGS_FILE"
}

main "$@"
