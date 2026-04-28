#!/usr/bin/env bash
# cc-monitor installer — dual-mode setup (direct / openclaw)
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/cc-monitor"
SETTINGS_FILE="$HOME/.claude/settings.json"
CRON_MARKER="# cc-monitor-entry"
HOOK_SCRIPT="$SCRIPT_DIR/cc-monitor.sh"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BOLD='\033[1m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; BLUE=''; NC=''
fi

info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die()   { error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
show_help() {
  cat <<'HELP'
cc-monitor installer — dual-mode

Usage:
  install.sh [OPTIONS]

Modes:
  --mode direct             Direct mode: webhook to Feishu + DingTalk
  --mode openclaw           OpenClaw mode: WeChat/Feishu via lobster, DingTalk webhook

Options:
  --interactive             Prompt for each configuration value
  --enable-watchdog         Register watchdog cron job (every 5 min)
  --enable-codex            Register Stop hook for Codex CLI
  --uninstall               Remove hooks, cron, optionally config
  --help                    Show this help

Examples:
  # Interactive setup (recommended)
  install.sh --interactive

  # Direct mode, non-interactive
  install.sh --mode direct --enable-watchdog

  # OpenClaw mode, non-interactive
  install.sh --mode openclaw --enable-watchdog

  # Direct mode with Codex CLI support
  install.sh --mode direct --enable-codex
HELP
}

# ---------------------------------------------------------------------------
# detect & check
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

check_dependencies() {
  local required=(bash tmux jq grep curl python3)
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
}

# ---------------------------------------------------------------------------
# config helpers
# ---------------------------------------------------------------------------
set_config_value() {
  local file="$1" key="$2" value="$3" section="$4"
  local in_section=false tmp
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

generate_config() {
  local mode="$1"
  local interactive="$2"

  mkdir -p "$CONFIG_DIR"
  if [[ ! -f "$SCRIPT_DIR/config.example.conf" ]]; then
    die "config.example.conf not found in $SCRIPT_DIR"
  fi
  if [[ -f "$CONFIG_DIR/config.conf" ]]; then
    if [[ "$interactive" == "true" ]]; then
      read -rp "Config already exists. Overwrite? [y/N] " answer
      [[ "${answer,,}" != "y" ]] && { info "Keeping existing config"; return 0; }
    else
      info "Config already exists, keeping it"
      return 0
    fi
  fi

  cp "$SCRIPT_DIR/config.example.conf" "$CONFIG_DIR/config.conf"
  chmod 0600 "$CONFIG_DIR/config.conf"
  set_config_value "$CONFIG_DIR/config.conf" "mode" "$mode" "monitor"
  info "Config created at $CONFIG_DIR/config.conf (mode=$mode)"
}

# ---------------------------------------------------------------------------
# direct mode config
# ---------------------------------------------------------------------------
prompt_direct_config() {
  local conf="$CONFIG_DIR/config.conf"
  echo ""
  printf "${BOLD}--- 直连模式配置 ---${NC}\n"
  printf "只需配置 webhook，不依赖任何外部服务\n\n"

  read -rp "启用钉钉（强通知，手表/手环）? [Y/n] " ans
  if [[ "${ans,,}" != "n" ]]; then
    set_config_value "$conf" "enabled" "true" "channel:dingtalk"
    read -rp "  钉钉 webhook URL: " webhook
    set_config_value "$conf" "webhook" "$webhook" "channel:dingtalk"
    read -rp "  钉钉 secret（可选，回车跳过）: " secret
    [[ -n "$secret" ]] && set_config_value "$conf" "secret" "$secret" "channel:dingtalk"
  fi

  read -rp "启用飞书（IM通知）? [Y/n] " ans
  if [[ "${ans,,}" != "n" ]]; then
    set_config_value "$conf" "enabled" "true" "channel:feishu"
    read -rp "  飞书 webhook URL: " webhook
    set_config_value "$conf" "webhook" "$webhook" "channel:feishu"
  fi
}

# ---------------------------------------------------------------------------
# openclaw mode config
# ---------------------------------------------------------------------------
prompt_openclaw_config() {
  local conf="$CONFIG_DIR/config.conf"
  echo ""
  printf "${BOLD}--- 龙虾模式配置 ---${NC}\n"
  printf "通过 OpenClaw 发送微信/飞书通知，支持远程输入\n\n"

  # detect openclaw
  if ! command -v openclaw &>/dev/null; then
    warn "openclaw 未安装"
    read -rp "是否自动安装 openclaw? [Y/n] " ans
    if [[ "${ans,,}" != "n" ]]; then
      npm install -g openclaw 2>/dev/null || die "openclaw 安装失败，请手动安装: npm install -g openclaw"
      info "openclaw 安装成功"
    else
      die "龙虾模式需要 openclaw，请先安装: npm install -g openclaw"
    fi
  fi

  # detect wechat login
  local has_account=false
  if openclaw channels list 2>/dev/null | grep -q "openclaw-weixin"; then
    has_account=true
    info "检测到已配置的微信通道"
  fi

  if ! $has_account; then
    echo ""
    printf "${YELLOW}需要登录微信${NC}\n"
    read -rp "现在扫码登录微信? [Y/n] " ans
    if [[ "${ans,,}" != "n" ]]; then
      openclaw-weixin login 2>/dev/null || openclaw channels login --channel weixin 2>/dev/null || {
        warn "自动登录失败，请手动运行: openclaw channels login --channel weixin"
      }
    fi
  fi

  # read openclaw config
  local wechat_account wechat_target
  wechat_account=$(openclaw channels list 2>/dev/null | grep "openclaw-weixin" | awk '{print $2}' | cut -d: -f1)
  if [[ -n "$wechat_account" ]]; then
    info "微信账号: $wechat_account"
    set_config_value "$conf" "enabled" "true" "channel:wechat"
    set_config_value "$conf" "openclaw_account" "$wechat_account" "channel:wechat"
    read -rp "  微信通知目标（如: o9cq805o4jn67kXBf0Sh7Qz0J2Wg@im.wechat）: " wechat_target
    set_config_value "$conf" "openclaw_target" "$wechat_target" "channel:wechat"
  fi

  # feishu via openclaw (optional)
  read -rp "也通过龙虾发飞书? [y/N] " ans
  if [[ "${ans,,}" == "y" ]]; then
    set_config_value "$conf" "enabled" "true" "channel:feishu-openclaw"
    local feishu_account feishu_target
    feishu_account=$(openclaw channels list 2>/dev/null | grep "openclaw-feishu" | awk '{print $2}' | cut -d: -f1)
    read -rp "  飞书 openclaw account（回车使用自动检测: $feishu_account）: " input
    [[ -n "$input" ]] && feishu_account="$input"
    set_config_value "$conf" "openclaw_account" "$feishu_account" "channel:feishu-openclaw"
    read -rp "  飞书通知目标: " feishu_target
    set_config_value "$conf" "openclaw_target" "$feishu_target" "channel:feishu-openclaw"
  fi

  # dingtalk (always webhook)
  read -rp "启用钉钉（强通知，手表/手环）? [Y/n] " ans
  if [[ "${ans,,}" != "n" ]]; then
    set_config_value "$conf" "enabled" "true" "channel:dingtalk"
    read -rp "  钉钉 webhook URL: " webhook
    set_config_value "$conf" "webhook" "$webhook" "channel:dingtalk"
    read -rp "  钉钉 secret（可选，回车跳过）: " secret
    [[ -n "$secret" ]] && set_config_value "$conf" "secret" "$secret" "channel:dingtalk"
  fi

  # openclaw agent config
  echo ""
  printf "${BOLD}--- 龙虾 Agent 配置 ---${NC}\n"
  read -rp "使用子 Agent 还是主 Agent? (推荐子Agent) [sub/main] " agent_ans
  if [[ "${agent_ans,,}" == "main" ]]; then
    set_config_value "$conf" "agent_mode" "main" "openclaw"
    info "使用龙虾主 Agent"
  else
    set_config_value "$conf" "agent_mode" "sub" "openclaw"
    local agent_name="cc-monitor"
    read -rp "  子 Agent 名称（回车使用 cc-monitor）: " name_input
    [[ -n "$name_input" ]] && agent_name="$name_input"
    set_config_value "$conf" "agent_name" "$agent_name" "openclaw"
    setup_openclaw_subagent "$agent_name"
  fi
}

setup_openclaw_subagent() {
  local agent_name="$1"
  info "创建龙虾子 Agent: $agent_name"

  if openclaw agents list 2>/dev/null | grep -q "$agent_name"; then
    info "子 Agent '$agent_name' 已存在，跳过创建"
    return 0
  fi

  local model
  model=$(openclaw config get agents.defaults.model.primary 2>/dev/null || echo "")
  if [[ -z "$model" ]]; then
    read -rp "  Agent model（如 zai/glm-5-turbo）: " model
  fi

  local workspace="$HOME/.openclaw/workspace"
  openclaw agents add "$agent_name" \
    ${model:+--model "$model"} \
    --workspace "$workspace" \
    --non-interactive 2>/dev/null

  if [[ $? -eq 0 ]]; then
    info "子 Agent '$agent_name' 创建成功"

    local wechat_enabled
    wechat_enabled=$(config_get_from_file "$CONFIG_DIR/config.conf" "channel:wechat:enabled" "false")
    if [[ "$wechat_enabled" == "true" ]]; then
      openclaw agents bind "$agent_name" --bind weixin 2>/dev/null && \
        info "已绑定微信通道到子 Agent" || \
        warn "绑定微信通道失败，可手动运行: openclaw agents bind $agent_name --bind weixin"
    fi
  else
    warn "子 Agent 创建失败，可手动运行: openclaw agents add $agent_name"
  fi
}

config_get_from_file() {
  local file="$1" lookup="$2" default="$3"
  local section="" line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" == *=* ]]; then
      key="${line%%=*}"
      key="${key#"${key%%[![:space:]]*}"}"
      key="${key%"${key##*[![:space:]]}"}"
      value="${line#*=}"
      if [[ "$section:${key}" == "$lookup" ]]; then
        printf '%s' "$value"
        return 0
      fi
    fi
  done < "$file"
  printf '%s' "$default"
}

# ---------------------------------------------------------------------------
# register hooks & cron
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
    local existing
    existing="$(jq -r --arg event "$event" --arg cmd "$hook_command" '
      .hooks[$event] // [] | map(select(.hooks[]?.command == $cmd)) | length
    ' "$settings" 2>/dev/null || echo "0")"

    if [[ "$existing" != "0" ]]; then
      info "Hook for $event already registered — skipping"
      continue
    fi

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

    local tmp
    tmp="$(mktemp)"
    jq --arg event "$event" --argjson entry "$entry" '
      .hooks[$event] = (.hooks[$event] // []) + [$entry]
    ' "$settings" > "$tmp" && mv "$tmp" "$settings" || { rm -f "$tmp"; }

    info "Registered hook for $event"
    changed=true
  done

  if $changed; then
    info "Hooks registered in $settings"
  fi
}

register_cron() {
  local enable_watchdog="${1:-false}"
  if ! $enable_watchdog; then
    info "No watchdog cron requested — skipping"
    return 0
  fi
  command -v crontab &>/dev/null || die "crontab command not found"
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v "$CRON_MARKER" > "$tmp" || true
  echo "LC_ALL=C.UTF-8 */5 * * * * cd $SCRIPT_DIR && bash cc-monitor.sh watchdog  $CRON_MARKER" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  info "Watchdog cron registered (every 5 minutes)"
}

register_codex_hook() {
  local codex_command="bash $HOOK_SCRIPT codex"
  local settings="$SETTINGS_FILE"

  if [[ ! -f "$settings" ]]; then
    mkdir -p "$(dirname "$settings")"
    echo '{}' > "$settings"
  fi

  local existing
  existing="$(jq -r --arg cmd "$codex_command" '
    .hooks["Stop"] // [] | map(select(.hooks[]?.command == $cmd)) | length
  ' "$settings" 2>/dev/null || echo "0")"

  if [[ "$existing" != "0" ]]; then
    info "Codex Stop hook already registered — skipping"
    return 0
  fi

  local entry
  entry="$(jq -n --arg cmd "$codex_command" '{
    matcher: "",
    hooks: [{ type: "command", command: $cmd }]
  }')"

  local tmp
  tmp="$(mktemp)"
  jq --argjson entry "$entry" '
    .hooks["Stop"] = (.hooks["Stop"] // []) + [$entry]
  ' "$settings" > "$tmp" && mv "$tmp" "$settings" || { rm -f "$tmp"; }

  info "Registered Codex Stop hook in $settings"
}

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------
do_uninstall() {
  printf "\n${BOLD}=== Uninstall cc-monitor ===${NC}\n\n"
  local hook_command="bash $HOOK_SCRIPT hook"

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
        ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE" || { rm -f "$tmp"; }
        info "Removed hook for $event"
      fi
    done
    # Also remove codex hook entries
    local codex_command="bash $HOOK_SCRIPT codex"
    local codex_events=("Stop")
    for event in "${codex_events[@]}"; do
      local existing
      existing="$(jq -r --arg event "$event" --arg cmd "$codex_command" '
        .hooks[$event] // [] | map(select(.hooks[]?.command == $cmd)) | length
      ' "$SETTINGS_FILE" 2>/dev/null || echo "0")"
      if [[ "$existing" != "0" ]]; then
        local tmp
        tmp="$(mktemp)"
        jq --arg event "$event" --arg cmd "$codex_command" '
          .hooks[$event] = (.hooks[$event] // []) | map(
            .hooks = (.hooks // []) | map(select(.command != $cmd))
          ) | map(select((.hooks | length) > 0))
        ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE" || { rm -f "$tmp"; }
        info "Removed codex hook for $event"
      fi
    done

    local tmp
    tmp="$(mktemp)"
    jq '.hooks = (.hooks | to_entries | map(select(.value | length > 0)) | from_entries)
    ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE" || { rm -f "$tmp"; }
  fi

  if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
    local tmp
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" > "$tmp"
    crontab "$tmp"
    rm -f "$tmp"
    info "Removed cc-monitor cron entries"
  fi

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
  local mode="" interactive=false enable_watchdog=false enable_codex=false do_uninstall_flag=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        mode="${2:-}"
        [[ -z "$mode" ]] && die "--mode requires a value (direct|openclaw)"
        [[ "$mode" != "direct" && "$mode" != "openclaw" ]] && die "Unknown mode: $mode"
        shift 2
        ;;
      --interactive)
        interactive=true
        shift
        ;;
      --enable-watchdog)
        enable_watchdog=true
        shift
        ;;
      --enable-codex)
        enable_codex=true
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

  # interactive mode selection
  if $interactive && [[ -z "$mode" ]]; then
    echo ""
    printf "${BOLD}选择安装模式:${NC}\n"
    echo "  1) 直连模式 — 飞书/钉钉 webhook，零依赖，只有通知"
    echo "  2) 龙虾模式 — 微信/飞书通过 OpenClaw，支持远程输入"
    echo ""
    read -rp "请选择 [1/2]: " mode_choice
    case "$mode_choice" in
      1) mode="direct" ;;
      2) mode="openclaw" ;;
      *) die "无效选择" ;;
    esac
  fi

  # default to direct if not specified
  [[ -z "$mode" ]] && mode="direct"

  info "cc-monitor installer (mode=$mode)"
  echo ""

  detect_platform
  check_dependencies
  generate_config "$mode" "$interactive"

  # Warn if no channels enabled in non-interactive mode
  if ! $interactive; then
    local conf="$CONFIG_DIR/config.conf"
    if [[ -f "$conf" ]]; then
      local any_enabled
      any_enabled="$(grep -c 'enabled=true' "$conf" 2>/dev/null)" || any_enabled=0
      if [[ "$any_enabled" == "0" ]]; then
        warn "No notification channels are enabled. Edit $CONFIG_DIR/config.conf to add your webhook URLs and enable channels before using cc-monitor."
      fi
    fi
  fi

  if $interactive; then
    if [[ "$mode" == "direct" ]]; then
      prompt_direct_config
    else
      prompt_openclaw_config
    fi

    read -rp "启用 watchdog 定时检查（每5分钟）? [Y/n] " ans
    [[ "${ans,,}" != "n" ]] && enable_watchdog=true
  fi

  register_hooks
  register_cron "$enable_watchdog"

  if $enable_codex; then
    register_codex_hook
  fi

  echo ""
  info "安装完成!"
  info "模式: $mode"
  info "配置: $CONFIG_DIR/config.conf"
  info "Hooks: $SETTINGS_FILE"
  if [[ "$mode" == "openclaw" ]]; then
    info ""
    info "远程输入: 在微信/飞书中直接发消息给龙虾即可控制 Claude Code"
  fi
}

main "$@"
