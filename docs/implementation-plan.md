# cc-monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the open-source cc-monitor project from scratch in /home/qb/cc-monitor/, migrating and refactoring from the existing ~/.openclaw/workspace/scripts/ codebase.

**Architecture:** Single bash entry point sourcing lib/ modules. Non-symmetric plugin interface: channels/ for outbound notifications, inputs/ for inbound remote commands. Three runtime paths: hook (event-driven), watchdog (cron), remote-input (daemon).

**Tech Stack:** Bash 4+, tmux, jq, grep -P, python3 (optional for webhook channels)

**Spec:** /home/qb/.openclaw/workspace/docs/superpowers/specs/2026-04-20-cc-monitor-opensource-design.md

**Source code (migration baseline):** /home/qb/.openclaw/workspace/scripts/cc-monitor-hook.sh

---

## File Map

| File | Responsibility | Source |
|------|---------------|--------|
| `cc-monitor.sh` | Entry point, dispatch to lib/ | New (replaces cc-monitor-hook.sh + watchdog.sh) |
| `lib/config.sh` | Load config.conf, env var override, validate | New |
| `lib/tmux.sh` | recover_session, capture_pane, is_alive | From cc-monitor-hook.sh lines 56-65, 84-88 |
| `lib/marker.sh` | create/update/cleanup/read marker JSON | From cc-monitor-hook.sh lines 94-112 |
| `lib/notify.sh` | Dispatch to enabled channels | New (from cc-monitor-hook.sh lines 67-82) |
| `lib/hooks.sh` | CC hook handlers (Stop/StopFailure/Permission/SessionEnd) | From cc-monitor-hook.sh lines 152-255, 387-437 |
| `lib/watchdog.sh` | Stuck detection, spinner regex, token tracking | From cc-monitor-hook.sh lines 257-395 |
| `channels/dingtalk.sh` | DingTalk webhook channel | From dingtalk_notify.py (rewrite as bash+curl) |
| `channels/feishu.sh` | Feishu webhook channel | New (similar to dingtalk) |
| `channels/wechat.sh` | WeChat via openclaw CLI | From cc-monitor-hook.sh lines 63-69 |
| `channels/_template.sh` | Channel plugin template | New |
| `inputs/wechat.sh` | WeChat message polling via openclaw | New |
| `inputs/_template.sh` | Input plugin template | New |
| `lib/remote-input.sh` | Command parsing, security, daemon loop | New |
| `config.example.conf` | Config template | New (from spec §5) |
| `install.sh` | Installer (interactive + non-interactive) | New |
| `install.md` | AI-driven install instructions | New |
| `tests/test_spinner.sh` | Spinner regex fixture tests | From tests/test_cc_monitor_hook.sh |
| `tests/test_hooks.sh` | Hook handler fixture tests | New |
| `tests/test_channels.sh` | Channel mock tests | New |
| `README.md` | English documentation | New |
| `README.zh-CN.md` | Chinese documentation | New |
| `LICENSE` | MIT license | New |

---

## Phase 1: Core Framework (hooks + notifications work)

### Task 1: Project scaffolding

**Files:**
- Create: `/home/qb/cc-monitor/` directory structure
- Create: `LICENSE`, `.gitignore`

- [ ] **Step 1: Create directory structure**

```bash
cd /home/qb/cc-monitor
mkdir -p lib channels inputs tests
```

- [ ] **Step 2: Create .gitignore**

```bash
cat > .gitignore << 'EOF'
config.conf
*.pyc
__pycache__/
/tmp/
*.log
*.pid
EOF
```

- [ ] **Step 3: Create MIT LICENSE**

```bash
curl -s https://raw.githubusercontent.com/licenses/license-templates/master/templates/mit.txt \
  | sed 's/<year>/2026/g; s/<copyright holders>/veniai/g' > LICENSE
```

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "chore: project scaffolding"
```

---

### Task 2: lib/config.sh — Config loader

**Files:**
- Create: `lib/config.sh`
- Create: `config.example.conf`

- [ ] **Step 1: Write config.example.conf**

Create `config.example.conf` with the exact content from spec §5 (wechat with account+target, dingtalk with webhook, feishu with webhook, input:wechat section, remote-input section).

- [ ] **Step 2: Write lib/config.sh**

Implement `config_load()`:
1. Resolve config path: `$CC_MONITOR_CONFIG` → `~/.config/cc-monitor/config.conf` → `./config.example.conf`
2. Parse INI sections into associative arrays: `declare -gA CFG_MONITOR=()`, `CFG_CHANNEL_WECHAT=()`, etc.
3. For each key, check env var `CC_MONITOR_<SECTION>_<KEY>` first (uppercase, colon→underscore)
4. Export commonly used values as globals: `MARKER_DIR`, `SAFE_TOOLS`, `WATCHDOG_INTERVAL`, etc.
5. `config_get "section:key" "default"` — helper to read any value
6. `config_validate()` — check required fields per enabled channel

- [ ] **Step 3: Syntax check**

```bash
bash -n lib/config.sh && echo "OK"
```

- [ ] **Step 4: Commit**

```bash
git add lib/config.sh config.example.conf
git commit -m "feat: config loader with env var override"
```

---

### Task 3: lib/tmux.sh — tmux utilities

**Files:**
- Create: `lib/tmux.sh`

- [ ] **Step 1: Write lib/tmux.sh**

Migrate from cc-monitor-hook.sh:
- `find_tmux_session()` — from lines 48-54
- `recover_session()` — from lines 56-65
- `capture_pane()` — new thin wrapper around `tmux capture-pane -p`
- `is_claude_alive()` — from lines 84-88
- `list_claude_panes()` — from watchdog line 384 (extract pane iteration)

All functions use `2>/dev/null || true` for fault tolerance.

- [ ] **Step 2: Syntax check**

```bash
bash -n lib/tmux.sh && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
git add lib/tmux.sh && git commit -m "feat: tmux utility functions"
```

---

### Task 4: lib/marker.sh — Marker file management

**Files:**
- Create: `lib/marker.sh`

- [ ] **Step 1: Write lib/marker.sh**

Migrate from cc-monitor-hook.sh:
- `marker_path()` — resolve marker file path for a session
- `marker_create()` — create marker with initial JSON (from lines 266-270, 339)
- `marker_update()` — atomic jq update (from lines 105-108)
- `marker_read()` — read a field from marker
- `marker_cleanup()` — remove marker file (from lines 110-112)
- `marker_ensure()` — create if not exists, fix corrupt JSON (from lines 267-275)

Uses `MARKER_DIR` from config.

- [ ] **Step 2: Syntax check**

```bash
bash -n lib/marker.sh && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
git add lib/marker.sh && git commit -m "feat: marker file management"
```

---

### Task 5: lib/notify.sh + channels/ — Notification framework

**Files:**
- Create: `lib/notify.sh`
- Create: `channels/_template.sh`
- Create: `channels/dingtalk.sh`
- Create: `channels/feishu.sh`
- Create: `channels/wechat.sh`

- [ ] **Step 1: Write channels/_template.sh**

Template implementing the `channel_send()` interface:
```bash
#!/usr/bin/env bash
# Channel plugin: <name>
# Required config in config.conf:
#   [channel:<name>]
#   enabled=true
#   # ... channel-specific fields

channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  # Implement: send notification to this channel
  # Return 0 on success, 1 on failure
  return 1
}
```

- [ ] **Step 2: Write channels/dingtalk.sh**

Rewrite dingtalk_notify.py as bash+curl:
```bash
channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  local webhook secret timestamp sign payload

  webhook=$(config_get "channel:dingtalk:webhook" "")
  secret=$(config_get "channel:dingtalk:secret" "")
  [[ -z "$webhook" ]] && return 1

  # Ensure keyword (~) is in text for DingTalk bot filter
  [[ "$short_msg" != *'~'* ]] && short_msg="~ ${short_msg}"

  # Optional HMAC signing
  local url="$webhook"
  if [[ -n "$secret" ]]; then
    timestamp=$(printf '%.0f' "$(date +%s)000")
    sign=$(printf '%s\n%s' "$timestamp" "$secret" \
      | openssl dgst -sha256 -hmac "$secret" -binary \
      | base64 | python3 -c "import sys,urllib.parse; print(urllib.parse.quote_plus(sys.stdin.read().strip()))")
    url="${webhook}&timestamp=${timestamp}&sign=${sign}"
  fi

  payload=$(jq -n --arg text "$short_msg" '{msgtype:"text",text:{content:$text}}')
  curl -sf -X POST "$url" \
    -H 'Content-Type: application/json' \
    -d "$payload" | jq -e '.errcode == 0' >/dev/null 2>&1
}
```

- [ ] **Step 3: Write channels/feishu.sh**

Similar to dingtalk but using Feishu webhook format:
```bash
channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  local webhook
  webhook=$(config_get "channel:feishu:webhook" "")
  [[ -z "$webhook" ]] && return 1

  local payload
  payload=$(jq -n --arg text "$short_msg" '{msg_type:"text",content:{text:$text}}')
  curl -sf -X POST "$webhook" \
    -H 'Content-Type: application/json' \
    -d "$payload" | jq -e '.code == 0' >/dev/null 2>&1
}
```

- [ ] **Step 4: Write channels/wechat.sh**

```bash
channel_send() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"
  local account target channel

  account=$(config_get "channel:wechat:account" "")
  target=$(config_get "channel:wechat:target" "")
  [[ -z "$account" || -z "$target" ]] && return 1

  # Append session name for easy forwarding
  local msg_with_session="${full_msg}\n\n📌 ${TMUX_SESSION:-unknown}"

  local _i
  for _i in 1 2 3; do
    openclaw message send \
      --channel openclaw-weixin \
      --account "$account" \
      --target "$target" \
      --message "$msg_with_session" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
```

- [ ] **Step 5: Write lib/notify.sh**

```bash
notify_user() {
  local full_msg="$1"
  local short_msg="${2:-$full_msg}"

  # Iterate all channel plugins in channels/ directory
  local plugin
  for plugin in "$SCRIPT_DIR/channels/"*.sh; do
    [[ -f "$plugin" ]] || continue
    # Check if channel is enabled in config
    local channel_name
    channel_name=$(basename "$plugin" .sh)
    local enabled
    enabled=$(config_get "channel:${channel_name}:enabled" "false")
    [[ "$enabled" != "true" ]] && continue

    # Source and call
    # shellcheck source=/dev/null
    source "$plugin"
    channel_send "$full_msg" "$short_msg" || true
  done
}
```

- [ ] **Step 6: Syntax check all files**

```bash
bash -n lib/notify.sh && bash -n channels/dingtalk.sh && bash -n channels/feishu.sh && bash -n channels/wechat.sh && echo "OK"
```

- [ ] **Step 7: Commit**

```bash
git add lib/notify.sh channels/ && git commit -m "feat: notification framework with wechat/dingtalk/feishu channels"
```

---

### Task 6: lib/hooks.sh — CC hooks handler

**Files:**
- Create: `lib/hooks.sh`

- [ ] **Step 1: Write lib/hooks.sh**

Migrate and refactor from cc-monitor-hook.sh lines 152-255, 387-437.

Key functions:
- `handle_stop()` — notify summary, update marker stop_seen=true (don't delete)
- `handle_stop_failure()` — check permanent error / claude alive / recovery budget → recover or notify
- `handle_permission_request()` — safe tool? auto-approve : notify + sleep 300 + approve
- `handle_session_end()` — cleanup marker
- `handle_hook_main()` — entry point: read stdin JSON, parse fields, find tmux session, dispatch

Important: `handle_hook_main` outputs JSON for PermissionRequest (approve/deny).

- [ ] **Step 2: Syntax check**

```bash
bash -n lib/hooks.sh && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
git add lib/hooks.sh && git commit -m "feat: CC hooks handler (Stop/StopFailure/Permission/SessionEnd)"
```

---

### Task 7: cc-monitor.sh — Main entry point

**Files:**
- Create: `cc-monitor.sh`

- [ ] **Step 1: Write cc-monitor.sh**

```bash
#!/usr/bin/env bash
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all lib modules
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
    echo "Usage: cc-monitor.sh {hook|watchdog [--dry-run]|remote-input [--stop]}"
    echo "  hook          CC hooks entry (reads JSON from stdin)"
    echo "  watchdog      Check for stuck sessions"
    echo "  remote-input  Start/stop remote input daemon"
    ;;
esac
```

- [ ] **Step 2: Make executable**

```bash
chmod +x cc-monitor.sh
```

- [ ] **Step 3: Integration test — hook with mock data**

```bash
echo '{"hook_event_name":"SessionEnd"}' | TMUX_PANE= LC_ALL=C.UTF-8 ./cc-monitor.sh hook
# Should exit cleanly (no tmux session found is OK for testing)
```

- [ ] **Step 4: Commit**

```bash
git add cc-monitor.sh && git commit -m "feat: main entry point with hook/watchdog/remote-input dispatch"
```

---

## Phase 2: Watchdog (stuck detection works)

### Task 8: lib/watchdog.sh — Stuck detection

**Files:**
- Create: `lib/watchdog.sh`

- [ ] **Step 1: Write lib/watchdog.sh**

Migrate from cc-monitor-hook.sh lines 257-395. Key functions:

- `handle_watchdog()` — iterate claude panes, check for stuck sessions
- Spinner regex: `^[·✢✳✶✻✽*].{0,80}…\s*\(\d+[hms]` (visible screen only)
- Token tracking: normalize token value, compare with previous, 15min timeout
- Wait time tracking: parse `(Xh Xm Xs)`, 10min timeout
- Recovery: max 2 attempts, then notify only
- Uses `recover_session()` from lib/tmux.sh
- Respects `DRY_RUN` flag

- [ ] **Step 2: Write tests/test_spinner.sh**

Fixture-based test with known spinner/non-spinner lines:
```bash
#!/usr/bin/env bash
set -u

# Test: active spinner lines should match
MATCH_LINES=(
  '✶ TaskName… (5m 30s · ↓ 2.3k tokens)'
  '· Thinking… (1h 2m 3s)'
  '✢ Running tests… (30s)'
)
# Test: non-spinner lines should NOT match
NOMATCH_LINES=(
  '  some indented output text'
  '✻ Completed for 5m 30s'
  '❯ prompt'
  'random log output'
)
# Run regex against each and assert
```

- [ ] **Step 3: Run tests**

```bash
bash tests/test_spinner.sh && echo "PASS"
```

- [ ] **Step 4: Commit**

```bash
git add lib/watchdog.sh tests/test_spinner.sh
git commit -m "feat: watchdog stuck detection with spinner/token tracking"
```

---

## Phase 3: Remote Input (bidirectional IM communication)

### Task 9: inputs/ — Input plugin framework

**Files:**
- Create: `inputs/_template.sh`
- Create: `inputs/wechat.sh`

- [ ] **Step 1: Write inputs/_template.sh**

Template implementing `input_poll()`:
```bash
#!/usr/bin/env bash
# Input plugin: <name>
# Required config in config.conf:
#   [input:<name>]
#   enabled=true
#   poll_interval=30

input_poll() {
  # Output JSON array to stdout: [{id, sender_id, chat_id, text, timestamp, channel}]
  # Return 0 on success, 1 on failure
  echo '[]'
  return 1
}
```

- [ ] **Step 2: Write inputs/wechat.sh**

```bash
input_poll() {
  local account
  account=$(config_get "channel:wechat:account" "")
  [[ -z "$account" ]] && { echo '[]'; return 1; }

  # Poll recent messages via openclaw CLI
  # Parse into standard format: [{id, sender_id, chat_id, text, timestamp, channel}]
  local raw
  raw=$(openclaw message receive \
    --channel openclaw-weixin \
    --account "$account" \
    --limit 20 2>/dev/null) || { echo '[]'; return 1; }

  echo "$raw" | jq -c '[.[] | {
    id: .id // .msgid // (.timestamp | tostring),
    sender_id: .sender // .from // "",
    chat_id: .chat // .group // "",
    text: .text // .content // "",
    timestamp: .timestamp // .ts // 0,
    channel: "wechat"
  }]' 2>/dev/null || echo '[]'
}
```

- [ ] **Step 3: Commit**

```bash
git add inputs/ && git commit -m "feat: input plugin framework with wechat polling"
```

---

### Task 10: lib/remote-input.sh — Command parsing, security, daemon

**Files:**
- Create: `lib/remote-input.sh`

- [ ] **Step 1: Write lib/remote-input.sh**

Key functions:
- `parse_command()` — extract @session and command from message text
  - Pattern: `@(\S+)\s+(.+)` → session=$1, command=$2
  - Special: `status`/`状态` without @session → return all sessions
- `is_command_allowed()` — check against `allowed_commands` list
- `is_sender_allowed()` — check sender_id/chat_id against whitelists (empty = trust all)
- `check_rate_limit()` — per-session rate limiting using `/tmp/cc-monitor/rate-*.json`
- `dedup_message()` — cursor-based dedup, skip already-processed message IDs
- `execute_command()` — dispatch to tmux:
  - `continue`/`继续` → `tmux send-keys -l -- "继续"` + Enter
  - `stop`/`停止` → `tmux send-keys Escape`
  - `status`/`状态` → capture all claude panes, notify_user with summary
- `remote_input_loop()` — main daemon loop:
  1. Source enabled input plugins
  2. Call input_poll()
  3. For each message: dedup → sender check → command check → rate limit → route → execute
  4. Update cursor
  5. Sleep poll_interval
- `remote_input_main()` — handle --stop (kill pidfile), handle --start (check pidfile, write pid, loop)

- [ ] **Step 2: Write tests/test_remote_input.sh**

Test command parsing and security:
- `parse_command "@2号 继续"` → session=2号, command=继续
- `parse_command "status"` → session="", command=status
- `parse_command "hello"` → rejected (no @session, not status)
- `is_command_allowed "继续"` → true
- `is_command_allowed "rm -rf"` → false
- Sender whitelist test: empty → allow, non-empty → check

- [ ] **Step 3: Run tests**

```bash
bash tests/test_remote_input.sh && echo "PASS"
```

- [ ] **Step 4: Commit**

```bash
git add lib/remote-input.sh tests/test_remote_input.sh
git commit -m "feat: remote input daemon with command parsing and security"
```

---

## Phase 4: Installer & Documentation (ready to open source)

### Task 11: install.sh — Installer

**Files:**
- Create: `install.sh`

- [ ] **Step 1: Write install.sh**

Functions:
- `check_dependencies()` — verify bash, tmux, jq, grep -P, python3, optionally openclaw
- `detect_platform()` — Linux/WSL OK, Windows native → error
- `generate_config()` — copy config.example.conf, prompt for channel params
- `register_hooks()` — read ~/.claude/settings.json, add hook entries idempotently
- `register_cron()` — add watchdog (*/5 * * * *) and remote-input cron entries idempotently
- `preview_changes()` — show hooks diff, cron diff, config before applying
- `do_install()` — orchestrate all steps
- `do_uninstall()` — remove hooks, cron entries, pidfile, config

Modes:
- `--interactive` — prompt for each choice
- `--channel X --enable-watchdog --enable-remote-input` — non-interactive
- `--uninstall` — remove everything
- No args — show help

- [ ] **Step 2: Make executable**

```bash
chmod +x install.sh
```

- [ ] **Step 3: Test install --help**

```bash
./install.sh --help
```

- [ ] **Step 4: Commit**

```bash
git add install.sh && git commit -m "feat: installer with interactive/non-interactive modes"
```

---

### Task 12: install.md — AI-driven install guide

**Files:**
- Create: `install.md`

- [ ] **Step 1: Write install.md**

Content: instructions for AI agents to follow when installing cc-monitor:
1. What this project does (1 paragraph)
2. Prerequisites check
3. Feature selection guide (monitoring only / monitoring + remote input)
4. Channel setup guide per channel (where to get credentials)
5. install.sh parameter reference
6. Post-install verification steps
7. Troubleshooting common issues

- [ ] **Step 2: Commit**

```bash
git add install.md && git commit -m "docs: AI-driven installation guide"
```

---

### Task 13: README.md + README.zh-CN.md

**Files:**
- Create: `README.md`
- Create: `README.zh-CN.md`

- [ ] **Step 1: Write README.md**

English README covering:
- One-line description + badges
- Screenshot/architecture diagram (ASCII)
- Quick start (one-liner AI install + script install)
- Features list (hooks, watchdog, remote input, channels)
- Channel setup guide (from spec §10)
- Configuration reference
- Platform support table
- Related projects (codesop, Claude-to-IM)
- License (MIT)

- [ ] **Step 2: Write README.zh-CN.md**

Chinese translation of README.md, adjusted for Chinese developer audience.

- [ ] **Step 3: Commit**

```bash
git add README.md README.zh-CN.md
git commit -m "docs: bilingual README"
```

---

### Task 14: Final integration + push

**Files:**
- All files

- [ ] **Step 1: Run all tests**

```bash
bash tests/test_spinner.sh && bash tests/test_remote_input.sh && echo "ALL PASS"
```

- [ ] **Step 2: Syntax check all scripts**

```bash
for f in cc-monitor.sh lib/*.sh channels/*.sh inputs/*.sh install.sh; do
  bash -n "$f" || echo "FAIL: $f"
done && echo "ALL OK"
```

- [ ] **Step 3: Verify .gitignore excludes config.conf**

```bash
echo "test" > config.conf && git status | grep -q config.conf && echo "FAIL: config.conf visible" || echo "OK: config.conf ignored"
rm -f config.conf
```

- [ ] **Step 4: Push to GitHub**

```bash
cd /home/qb/cc-monitor && git add -A && git commit -m "feat: cc-monitor v1.0.0" && git push -u origin master
```

---

## Spec Coverage Check

| Spec Section | Covered By Task |
|---|---|
| §1 项目定位 | Task 13 (README) |
| §2 目录结构 | Task 1 |
| §3.1 入口脚本 | Task 7 |
| §3.2 模块职责 | Tasks 2-6, 8, 10 |
| §3.3 渠道接口 | Task 5, 9 |
| §3.4 数据流 | Tasks 6, 7, 8, 10 |
| §4 安装体验 | Tasks 11, 12 |
| §5 配置文件 | Task 2 |
| §6 远程输入安全 | Task 10 |
| §7 Spinner 检测 | Task 8 |
| §8 并发策略 | Task 4 (marker atomic mv) |
| §9 测试策略 | Tasks 8, 10 |
| §10 渠道获取指南 | Task 13 (README) |
| §11 V1 范围 | All tasks |
