# 双模式架构重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 cc-monitor 重构为双模式架构：直连模式（零依赖）和龙虾模式（完整功能），清理残留代码，重写文档。

**Architecture:** 两种安装模式互斥，用户只选一种。直连模式用 webhook 发飞书+钉钉通知，无远程输入。龙虾模式通过 openclaw CLI 发微信/飞书通知，钉钉始终走 webhook（手表强通知），龙虾同时提供远程输入能力。

**Tech Stack:** Bash 4+, jq, tmux, grep -P, curl, openclaw CLI（仅龙虾模式）

---

## 文件变动总览

| 文件 | 操作 | 职责 |
|------|------|------|
| `config.example.conf` | 重写 | 双模式配置模板，删 remote-input 残留 |
| `channels/dingtalk.sh` | 保留不变 | webhook 直连，强通知（两个模式通用） |
| `channels/feishu.sh` | 重写 | 支持双模式：webhook（直连）或 openclaw CLI（龙虾） |
| `channels/wechat.sh` | 重写 | 仅龙虾模式，通过 openclaw CLI 发微信 |
| `channels/_template.sh` | 保留不变 | 插件模板 |
| `lib/notify.sh` | 小改 | 传入 mode 参数，供 channel 判断发送方式 |
| `lib/hooks.sh` | 小改 | notify_user 传入 mode |
| `lib/config.sh` | 小改 | config_validate 适配双模式，加 mode 全局变量 |
| `lib/watchdog.sh` | 不改 | 逻辑不变 |
| `lib/tmux.sh` | 不改 | 逻辑不变 |
| `lib/marker.sh` | 不改 | 逻辑不变 |
| `cc-monitor.sh` | 小改 | 删除 codex 入口（不在开源版范围），保留 hook + watchdog |
| `install.sh` | 重写 | 双模式安装流程，龙虾模式自动配置 Agent |
| `install.md` | 重写 | AI 驱动安装说明 |
| `README.md` | 重写 | 中文主文档，双模式架构说明 |
| `README.zh-CN.md` | 删除 | 合并到 README.md，不再分两个文件 |
| `tests/test_spinner.sh` | 保留不变 | spinner 测试 |

---

### Task 1: config.example.conf 双模式重写

**Files:**
- Rewrite: `config.example.conf`

- [ ] **Step 1: 重写 config.example.conf**

```ini
# cc-monitor 配置文件
# 两种模式二选一：direct（直连）或 openclaw（龙虾）

[monitor]
# 模式选择：direct 或 openclaw
mode=direct
watchdog_interval=300
auto_recovery_max=2
safe_tools=Read,Glob,Grep,Agent,TaskCreate,TaskGet,TaskList,TaskUpdate
auto_approve_permissions=true
auto_approve_timeout=300
debug=false
marker_dir=/tmp/cc-monitor

# ===== 模式一：直连（不依赖龙虾）=====

# 强通知通道（手表/手环提醒）—— 固定钉钉，后续可扩展
[channel:dingtalk]
enabled=false
webhook=
secret=

# IM 通知通道（直连模式用 webhook）
[channel:feishu]
enabled=false
webhook=

# ===== 模式二：龙虾（完整功能）=====
# 以下配置仅在 mode=openclaw 时生效

# IM 交互通道：微信（通过龙虾）
[channel:wechat]
enabled=false
openclaw_channel=openclaw-weixin
openclaw_account=
openclaw_target=

# IM 交互通道：飞书（通过龙虾）
[channel:feishu-openclaw]
enabled=false
openclaw_channel=openclaw-feishu
openclaw_account=
openclaw_target=

# ===== 龙虾模式 Agent 配置 =====
[openclaw]
# 子 Agent（推荐）或 main
agent_mode=sub
agent_name=cc-monitor
agent_model=
```

- [ ] **Step 2: Commit**

```bash
git add config.example.conf
git commit -m "refactor: dual-mode config template (direct + openclaw)"
```

---

### Task 2: lib/config.sh 适配双模式

**Files:**
- Modify: `lib/config.sh`

- [ ] **Step 1: 在 `_config_export_globals()` 中加入 `CC_MODE` 全局变量**

在 `lib/config.sh:75` 的 `_config_export_globals()` 函数中，在 `MARKER_DIR=` 行之前加入：

```bash
CC_MODE="$(config_get "monitor:mode" "direct")"
```

并在 export 行加入 `CC_MODE`：

```bash
export CC_MODE MARKER_DIR WATCHDOG_INTERVAL AUTO_RECOVERY_MAX SAFE_TOOLS_LIST DEBUG_MODE
```

- [ ] **Step 2: 重写 `config_validate()` 适配双模式**

将 `lib/config.sh:106-141` 的 `config_validate()` 替换为：

```bash
config_validate() {
    local mode errors=0
    mode="$(config_get "monitor:mode" "direct")"

    # dingtalk — 两个模式都需要 webhook
    local enabled webhook
    enabled="$(config_get "channel:dingtalk:enabled" "false")"
    if [[ "$enabled" == "true" ]]; then
        webhook="$(config_get "channel:dingtalk:webhook" "")"
        if [[ -z "$webhook" ]]; then
            echo "[WARN] channel:dingtalk enabled but 'webhook' is empty" >&2
            ((errors++))
        fi
    fi

    if [[ "$mode" == "direct" ]]; then
        # 直连模式：feishu 用 webhook
        enabled="$(config_get "channel:feishu:enabled" "false")"
        if [[ "$enabled" == "true" ]]; then
            webhook="$(config_get "channel:feishu:webhook" "")"
            if [[ -z "$webhook" ]]; then
                echo "[WARN] channel:feishu enabled but 'webhook' is empty" >&2
                ((errors++))
            fi
        fi
    elif [[ "$mode" == "openclaw" ]]; then
        # 龙虾模式：wechat / feishu-openclaw 需要 openclaw 配置
        enabled="$(config_get "channel:wechat:enabled" "false")"
        if [[ "$enabled" == "true" ]]; then
            if [[ -z "$(config_get "channel:wechat:openclaw_account" "")" ]]; then
                echo "[WARN] channel:wechat enabled but 'openclaw_account' is empty" >&2
                ((errors++))
            fi
            if [[ -z "$(config_get "channel:wechat:openclaw_target" "")" ]]; then
                echo "[WARN] channel:wechat enabled but 'openclaw_target' is empty" >&2
                ((errors++))
            fi
        fi
        enabled="$(config_get "channel:feishu-openclaw:enabled" "false")"
        if [[ "$enabled" == "true" ]]; then
            if [[ -z "$(config_get "channel:feishu-openclaw:openclaw_account" "")" ]]; then
                echo "[WARN] channel:feishu-openclaw enabled but 'openclaw_account' is empty" >&2
                ((errors++))
            fi
            if [[ -z "$(config_get "channel:feishu-openclaw:openclaw_target" "")" ]]; then
                echo "[WARN] channel:feishu-openclaw enabled but 'openclaw_target' is empty" >&2
                ((errors++))
            fi
        fi
    else
        echo "[ERROR] Unknown mode '$mode' — must be 'direct' or 'openclaw'" >&2
        ((errors++))
    fi

    return "$errors"
}
```

- [ ] **Step 3: Commit**

```bash
git add lib/config.sh
git commit -m "refactor: config supports dual-mode (direct/openclaw)"
```

---

### Task 3: channels/ 双模式改造

**Files:**
- Rewrite: `channels/wechat.sh`
- Rewrite: `channels/feishu.sh`
- Keep: `channels/dingtalk.sh`（不变）

- [ ] **Step 1: 重写 `channels/wechat.sh`（龙虾模式专用）**

```bash
#!/usr/bin/env bash
# WeChat channel — via OpenClaw CLI (龙虾模式)
# 仅在 mode=openclaw 时启用

channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  local account target channel

  channel=$(config_get "channel:wechat:openclaw_channel" "openclaw-weixin")
  account=$(config_get "channel:wechat:openclaw_account" "")
  target=$(config_get "channel:wechat:openclaw_target" "")
  [[ -z "$account" || -z "$target" ]] && return 1

  local msg_with_session="${full_msg}\n\n📌 ${TMUX_SESSION:-unknown}"

  local _i
  for _i in 1 2 3; do
    openclaw message send \
      --channel "$channel" \
      --account "$account" \
      --target "$target" \
      --message "$msg_with_session" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
```

- [ ] **Step 2: 重写 `channels/feishu.sh`（支持双模式）**

在直连模式下，飞书走 webhook（当前实现）。在龙虾模式下，飞书走 openclaw CLI。

但 notify.sh 遍历 channels/ 目录时，文件名就是 channel 名。直连模式用 `feishu.sh`，龙虾模式用 `feishu-openclaw.sh`。

所以改为：`feishu.sh` 只负责 webhook 直连（直连模式），新建 `channels/feishu-openclaw.sh` 负责龙虾模式。

`channels/feishu.sh` 保持当前 webhook 实现不变（已经是正确的）。

新建 `channels/feishu-openclaw.sh`：

```bash
#!/usr/bin/env bash
# Feishu channel — via OpenClaw CLI (龙虾模式)
# 仅在 mode=openclaw 时启用

channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  local account target channel

  channel=$(config_get "channel:feishu-openclaw:openclaw_channel" "openclaw-feishu")
  account=$(config_get "channel:feishu-openclaw:openclaw_account" "")
  target=$(config_get "channel:feishu-openclaw:openclaw_target" "")
  [[ -z "$account" || -z "$target" ]] && return 1

  local msg_with_session="${full_msg}\n\n📌 ${TMUX_SESSION:-unknown}"

  local _i
  for _i in 1 2 3; do
    openclaw message send \
      --channel "$channel" \
      --account "$account" \
      --target "$target" \
      --message "$msg_with_session" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
```

- [ ] **Step 3: 更新 `_template.sh` 注释**

在 `channels/_template.sh` 顶部注释中加入双模式说明：

```bash
#!/usr/bin/env bash
# Channel plugin template
#
# To create a new channel:
# 1. Copy this file to channels/<name>.sh
# 2. Implement channel_send()
# 3. Add [channel:<name>] section to config.example.conf
#
# Two modes:
#   - Direct mode (webhook):  channel sends via curl to webhook URL
#   - OpenClaw mode (龙虾):   channel sends via 'openclaw message send' CLI
#
# notify.sh auto-discovers all *.sh files (except _template.sh)
# and calls channel_send() if the channel is enabled in config.

channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  # Implement: send notification to this channel
  # Return 0 on success, 1 on failure
  return 1
}
```

- [ ] **Step 4: Commit**

```bash
git add channels/
git commit -m "refactor: channels support dual-mode (webhook + openclaw)"
```

---

### Task 4: cc-monitor.sh 清理入口

**Files:**
- Modify: `cc-monitor.sh`

- [ ] **Step 1: 删除 codex 入口，只保留 hook + watchdog**

当前 `cc-monitor.sh:20-25` 有 `hook`、`codex`、`watchdog` 三个入口。codex 不在开源版范围，删除。

同时更新 help 文本。

将 `cc-monitor.sh` 完整替换为：

```bash
#!/usr/bin/env bash
# cc-monitor — Claude Code remote monitoring tool
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

case "${1:-help}" in
  hook)
    handle_hook_main
    ;;
  watchdog)
    DRY_RUN=false
    [[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true
    handle_watchdog
    ;;
  help|*)
    cat <<'USAGE'
cc-monitor — Claude Code remote monitoring tool

Usage: cc-monitor.sh <command> [options]

Commands:
  hook                CC hooks entry (reads JSON from stdin)
  watchdog [--dry-run]  Check for stuck sessions
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
```

- [ ] **Step 2: Commit**

```bash
git add cc-monitor.sh
git commit -m "refactor: simplify entry point, remove codex, dual-mode help text"
```

---

### Task 5: install.sh 双模式安装重写

**Files:**
- Rewrite: `install.sh`

install.sh 是改动最大的文件。核心变化：
1. 安装时先选模式（直连 / 龙虾）
2. 直连模式：只需填 webhook URL
3. 龙虾模式：检测/引导安装 openclaw，扫码登录，配置龙虾 Agent
4. 删除 remote-input 相关代码
5. 用户只选一种模式，不会两个都装

- [ ] **Step 1: 重写 install.sh**

```bash
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
  --uninstall               Remove hooks, cron, optionally config
  --help                    Show this help

Examples:
  # Interactive setup (recommended)
  install.sh --interactive

  # Direct mode, non-interactive
  install.sh --mode direct --enable-watchdog

  # OpenClaw mode, non-interactive
  install.sh --mode openclaw --enable-watchdog
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
  local required=(bash tmux jq grep curl)
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
# 直连模式配置
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
# 龙虾模式配置
# ---------------------------------------------------------------------------
prompt_openclaw_config() {
  local conf="$CONFIG_DIR/config.conf"
  echo ""
  printf "${BOLD}--- 龙虾模式配置 ---${NC}\n"
  printf "通过 OpenClaw 发送微信/飞书通知，支持远程输入\n\n"

  # 检测 openclaw
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

  # 检测龙虾是否已登录
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

  # 读取龙虾配置
  local wechat_account wechat_target
  wechat_account=$(openclaw channels list 2>/dev/null | grep "openclaw-weixin" | awk '{print $2}' | cut -d: -f1)
  if [[ -n "$wechat_account" ]]; then
    info "微信账号: $wechat_account"
    set_config_value "$conf" "enabled" "true" "channel:wechat"
    set_config_value "$conf" "openclaw_account" "$wechat_account" "channel:wechat"
    read -rp "  微信通知目标（如: o9cq805o4jn67kXBf0Sh7Qz0J2Wg@im.wechat）: " wechat_target
    set_config_value "$conf" "openclaw_target" "$wechat_target" "channel:wechat"
  fi

  # 飞书（可选，也通过龙虾）
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

  # 钉钉（手表强通知，始终 webhook）
  read -rp "启用钉钉（强通知，手表/手环）? [Y/n] " ans
  if [[ "${ans,,}" != "n" ]]; then
    set_config_value "$conf" "enabled" "true" "channel:dingtalk"
    read -rp "  钉钉 webhook URL: " webhook
    set_config_value "$conf" "webhook" "$webhook" "channel:dingtalk"
    read -rp "  钉钉 secret（可选，回车跳过）: " secret
    [[ -n "$secret" ]] && set_config_value "$conf" "secret" "$secret" "channel:dingtalk"
  fi

  # 龙虾 Agent 配置
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

  # 检查是否已存在
  if openclaw agents list 2>/dev/null | grep -q "$agent_name"; then
    info "子 Agent '$agent_name' 已存在，跳过创建"
    return 0
  fi

  # 获取 model（从龙虾配置读取，或让用户输入）
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

    # 绑定微信通道（如果已配置）
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
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"

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
        ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
        info "Removed hook for $event"
      fi
    done
    local tmp
    tmp="$(mktemp)"
    jq '.hooks = (.hooks | to_entries | map(select(.value | length > 0)) | from_entries)
    ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
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
  local mode="" interactive=false enable_watchdog=false do_uninstall_flag=false

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

  # 交互模式下选模式
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

  # 非交互且没指定模式，默认直连
  [[ -z "$mode" ]] && mode="direct"

  info "cc-monitor installer (mode=$mode)"
  echo ""

  detect_platform
  check_dependencies
  generate_config "$mode" "$interactive"

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
```

- [ ] **Step 2: Commit**

```bash
git add install.sh
git commit -m "refactor: dual-mode installer (direct + openclaw)"
```

---

### Task 6: README 重写（中文主文档）

**Files:**
- Rewrite: `README.md`（中文主文档）
- Delete: `README.zh-CN.md`（合并到主文档）

- [ ] **Step 1: 删除 `README.zh-CN.md`**

```bash
git rm README.zh-CN.md
```

- [ ] **Step 2: 重写 `README.md`**

```markdown
# cc-monitor

[English](README.en.md) | 中文

Claude Code 远程监控工具。任务完成时收到通知，自动恢复卡住的会话。

```
  你的电脑 (tmux)                       你的手机/手表
┌─────────────────────┐             ┌──────────────┐
│  ✶ 重构登录模块…     │── 通知 ───→│  📱 微信/飞书  │ ← 查看详情
│  (Claude 在跑)       │             │  ⌚ 钉钉      │ ← 手腕震动提醒
│                      │             └──────────────┘
│                      │← 远程输入 ──  📱 发消息控制 Claude
└─────────────────────┘
```

## 两种安装模式

### 模式一：直连（零依赖）

不装任何外部服务，填 webhook URL 就能用。

| 通道 | 方式 | 用途 |
|------|------|------|
| 钉钉 | webhook 直连 | 强通知（手表/手环震动） |
| 飞书 | webhook 直连 | IM 通知 |

只有通知，没有远程输入。

### 模式二：装龙虾（完整功能）

通过 [OpenClaw（龙虾）](https://github.com/veniai/openclaw) 连接微信和飞书，支持远程输入。

| 通道 | 方式 | 用途 |
|------|------|------|
| 钉钉 | webhook 直连 | 强通知（手表/手环震动） |
| 微信 | OpenClaw | IM 通知 + 远程输入 |
| 飞书 | OpenClaw | IM 通知 + 远程输入 |

**两种模式互斥，只选一种。**

> **为什么钉钉始终走 webhook？** 钉钉是专用的强通知通道，发短消息到手表/手环，手腕一震就知道任务完成了。微信/飞书是日常聊天工具，拿来震手腕会太吵。

## 快速开始

### AI 驱动安装（推荐）

告诉你的 Claude Code：

```
请按照 https://github.com/veniai/cc-monitor/blob/main/install.md 安装 cc-monitor
```

### 手动安装

```bash
git clone https://github.com/veniai/cc-monitor.git
cd cc-monitor

# 交互式安装（会引导你选模式）
./install.sh --interactive

# 或非交互式
./install.sh --mode direct --enable-watchdog      # 直连模式
./install.sh --mode openclaw --enable-watchdog     # 龙虾模式
```

## 前置依赖

- **Claude Code**（CLI 工具）
- **tmux** — 终端复用器
- **jq** — JSON 处理器
- **grep -P** — Perl 正则（GNU grep）
- **bash 4+**
- **python3**（可选，钉钉加签需要）
- **openclaw** CLI（仅龙虾模式需要）

平台：**Linux** 或 **WSL**。

## 配置

复制 `config.example.conf` 到 `~/.config/cc-monitor/config.conf`。

### 直连模式配置

```ini
[monitor]
mode=direct

[channel:dingtalk]
enabled=true
webhook=https://oapi.dingtalk.com/robot/send?access_token=xxx
secret=

[channel:feishu]
enabled=true
webhook=https://open.feishu.cn/open-apis/bot/v2/hook/xxx
```

### 龙虾模式配置

```ini
[monitor]
mode=openclaw

[channel:dingtalk]
enabled=true
webhook=https://oapi.dingtalk.com/robot/send?access_token=xxx

[channel:wechat]
enabled=true
openclaw_channel=openclaw-weixin
openclaw_account=你的account
openclaw_target=你的target@im.wechat

[openclaw]
agent_mode=sub
agent_name=cc-monitor
```

环境变量覆盖：`CC_MONITOR_<SECTION>_<KEY>`（如 `CC_MONITOR_CHANNEL_DINGTALK_WEBHOOK`）。

## 渠道设置

### 钉钉（强通知，两个模式通用）

1. 钉钉群 → 设置 → 智能群助手 → 添加机器人 → 自定义
2. 复制 webhook URL
3. 可选：开启加签，复制 secret

### 飞书 — 直连模式

1. 飞书群 → 设置 → 群机器人 → 添加机器人 → 自定义机器人
2. 复制 webhook URL

### 微信 / 飞书 — 龙虾模式

1. 安装龙虾：`npm install -g openclaw`
2. 运行 `openclaw channels login --channel weixin`（或 feishu）
3. install.sh 会自动读取龙虾配置

## 使用方式

### Hook 模式（自动触发）

安装后自动注册为 Claude Code hooks，任务完成/出错/请求权限时自动通知。

### Watchdog 模式（定时检查）

```bash
./cc-monitor.sh watchdog            # 检测卡住的会话
./cc-monitor.sh watchdog --dry-run  # 仅预览，不执行恢复
```

## 架构

```
cc-monitor.sh           # 唯一入口
├── lib/
│   ├── config.sh       # 配置加载（INI + 环境变量 + 双模式）
│   ├── hooks.sh        # CC hook 处理器
│   ├── watchdog.sh     # 卡住检测 + 自动恢复
│   ├── tmux.sh         # tmux 工具函数
│   ├── notify.sh       # 通知分发（遍历启用的 channels）
│   └── marker.sh       # 会话状态文件
├── channels/           # 通知渠道插件
│   ├── dingtalk.sh     # 钉钉 webhook（强通知）
│   ├── feishu.sh       # 飞书 webhook（直连模式）
│   ├── feishu-openclaw.sh  # 飞书 openclaw（龙虾模式）
│   ├── wechat.sh       # 微信 openclaw（龙虾模式）
│   └── _template.sh    # 新渠道模板
└── docs/
    └── plans/          # 开发计划
```

### 添加新渠道

1. 复制 `channels/_template.sh` 到 `channels/你的渠道.sh`
2. 实现 `channel_send()` 函数
3. 在配置文件中添加 `[channel:你的渠道]` section
4. 完成 — notify.sh 自动发现新渠道

## 卸载

```bash
./install.sh --uninstall
```

## 平台支持

| 平台 | 状态 |
|------|------|
| Linux (Ubuntu/Debian) | 完全支持 |
| WSL (Windows) | 完全支持 |
| macOS | 部分 — 缺少 `grep -P`、`flock`、`md5sum`。可通过 Homebrew 安装 GNU 工具。 |
| Windows 原生 | 不支持（依赖 tmux） |

## 相关项目

- **[OpenClaw（龙虾）](https://github.com/veniai/openclaw)** — IM 桥接平台，提供微信/飞书双向通信
- **[Claude-to-IM](https://github.com/veniai/Claude-to-IM-skill)** — Claude Code 桥接到 IM 平台
- **[codesop](https://github.com/veniai/codesop)** — AI 编码 SOP

## 许可证

[MIT](LICENSE)
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git rm README.zh-CN.md
git commit -m "docs: rewrite README as Chinese primary, dual-mode architecture"
```

---

### Task 7: install.md 更新

**Files:**
- Rewrite: `install.md`

- [ ] **Step 1: 重写 install.md（AI 驱动安装说明）**

更新为反映双模式安装流程。install.md 是给 Claude Code 读的，让 Claude Code 帮用户安装。

```markdown
# cc-monitor 安装指南（AI 驱动）

本文档供 Claude Code 读取，帮助用户安装 cc-monitor。

## 安装步骤

### 1. 克隆仓库

```bash
git clone https://github.com/veniai/cc-monitor.git ~/cc-monitor
```

### 2. 询问用户选择模式

问用户：
- **直连模式**：只需飞书/钉钉 webhook，零依赖。只有通知，没有远程输入。
- **龙虾模式**：通过 OpenClaw 连微信/飞书，支持远程输入。需要安装 openclaw。

### 3. 创建配置文件

```bash
mkdir -p ~/.config/cc-monitor
cp ~/cc-monitor/config.example.conf ~/.config/cc-monitor/config.conf
chmod 0600 ~/.config/cc-monitor/config.conf
```

根据用户选择的模式，编辑 `config.conf`：

- 直连模式：设置 `mode=direct`，填入飞书/钉钉 webhook URL
- 龙虾模式：设置 `mode=openclaw`，检测 openclaw 配置，填入微信/飞书 target

### 4. 注册 Claude Code Hooks

在 `~/.claude/settings.json` 的 `hooks` 中添加：

```json
{
  "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/cc-monitor/cc-monitor.sh hook" }] }],
  "StopFailure": [{ "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/cc-monitor/cc-monitor.sh hook" }] }],
  "PermissionRequest": [{ "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/cc-monitor/cc-monitor.sh hook" }] }],
  "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/cc-monitor/cc-monitor.sh hook", "timeout": 5000 }] }]
}
```

### 5. 注册 Watchdog Cron（可选）

```bash
# 每 5 分钟检查一次卡住的会话
(crontab -l 2>/dev/null | grep -v cc-monitor; echo "LC_ALL=C.UTF-8 */5 * * * * cd ~/cc-monitor && bash cc-monitor.sh watchdog # cc-monitor") | crontab -
```

### 6. 龙虾模式额外步骤

如果用户选了龙虾模式：

1. 确认 openclaw 已安装：`command -v openclaw`
2. 确认微信通道已登录：`openclaw channels list | grep weixin`
3. 创建子 Agent（推荐）：`openclaw agents add cc-monitor --bind weixin`
4. 绑定路由：`openclaw agents bind cc-monitor --bind weixin`

### 7. 验证

手动触发一次测试：

```bash
echo '{"hook_event_name":"Stop","last_assistant_message":"测试安装是否成功"}' | bash ~/cc-monitor/cc-monitor.sh hook
```

检查手机/手表是否收到通知。
```

- [ ] **Step 2: Commit**

```bash
git add install.md
git commit -m "docs: update AI-driven install guide for dual-mode"
```

---

### Task 8: hooks.sh 小改

**Files:**
- Modify: `lib/hooks.sh`

- [ ] **Step 1: 在 `handle_hook_main()` 中加入 mode 打印到 debug dump**

在 `lib/hooks.sh:190` 的 `dump_debug` 之后，加一行日志输出当前模式：

```bash
dump_debug
[[ "${DEBUG_MODE:-false}" == "true" ]] && echo "[cc-monitor] mode=${CC_MODE:-unknown} session=$TMUX_SESSION event=$event" >&2
```

- [ ] **Step 2: 删除 `handle_codex_stop()` 函数**

删除 `lib/hooks.sh:207-222` 的 `handle_codex_stop()` 函数（codex 不在开源版范围）。

- [ ] **Step 3: Commit**

```bash
git add lib/hooks.sh
git commit -m "refactor: hooks cleanup — remove codex handler, add mode debug"
```

---

### Task 9: 最终清理

**Files:**
- All files

- [ ] **Step 1: 删除不存在的文件引用**

检查 `cc-monitor.sh` 中 `source` 的文件是否都存在。确保没有引用已删除的 `lib/remote-input.sh`。

当前 `cc-monitor.sh` 已经在 Task 4 中重写，不含 remote-input。

- [ ] **Step 2: 确认 tests/test_spinner.sh 仍可运行**

```bash
cd ~/cc-monitor && bash tests/test_spinner.sh
```

预期：所有 16 个 spinner 测试通过。

- [ ] **Step 3: 最终 Commit**

```bash
git add -A
git commit -m "chore: final cleanup, verify tests pass"
```
