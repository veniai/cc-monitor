# cc-monitor Installation Guide (for AI Agents)

> This document is designed to be read by AI coding assistants (Claude Code, Codex, OpenClaw).
> If you're a human, see [README.md](README.md) for a friendlier guide.

## What This Project Does

cc-monitor monitors Claude Code sessions running in tmux. It sends notifications to IM (WeChat/DingTalk/Feishu) when tasks complete, auto-recovers stuck sessions, and optionally accepts remote commands from IM.

## Prerequisites Check

Before installing, verify these exist:

```bash
# Required
command -v bash && bash --version | head -1   # bash 4+
command -v tmux && tmux -V                      # tmux 1.6+
command -v jq && jq --version                   # jq 1.5+
echo "test" | grep -Pq "test" && echo "grep -P OK"  # GNU grep with PCRE

# Optional (per channel)
command -v openclaw && echo "openclaw OK"       # WeChat channel
command -v python3 && python3 --version          # DingTalk signing
```

If any required tool is missing, install it first:
```bash
# Ubuntu/Debian
sudo apt install bash tmux jq grep python3

# WSL
sudo apt install bash tmux jq grep python3
```

## Installation Steps

### Step 1: Ask the user what they want

Present these choices:

1. **Notification channels** — Which IM to use?
   - WeChat (requires openclaw CLI + account + target)
   - DingTalk (requires webhook URL)
   - Feishu (requires webhook URL)
   - Multiple channels OK

2. **Watchdog** — Enable stuck session detection? (recommended: yes)
   - Runs every 5 minutes via cron
   - Auto-recovers frozen sessions (up to 2 times, then alerts)

3. **Remote input** — Enable IM remote commands? (optional)
   - Accept commands like `@session 继续`, `@session 停止`, `状态`
   - Requires an input-capable channel (currently only WeChat via openclaw)

### Step 2: Gather channel credentials

#### WeChat (via OpenClaw)

```
1. Install: pip install openclaw
2. Login: openclaw login
3. Get account ID: openclaw account list
4. Get target: openclaw contact list → format is "id@im.wechat"
```

Required config fields: `account`, `target`

#### DingTalk

```
1. Open DingTalk group → Settings → Smart Group Assistant → Add Robot → Custom
2. Copy the webhook URL (https://oapi.dingtalk.com/robot/send?access_token=xxx)
3. Optional: enable signing, copy the secret
```

Required config fields: `webhook`

#### Feishu

```
1. Open Feishu group → Settings → Bots → Add Bot → Custom Bot
2. Copy the webhook URL (https://open.feishu.cn/open-apis/bot/v2/hook/xxx)
3. Optional: configure signing key
```

Required config fields: `webhook`

### Step 3: Run the installer

```bash
cd /path/to/cc-monitor

# If user selected specific options:
./install.sh --channel wechat --enable-watchdog --enable-remote-input

# Or use interactive mode to guide the user:
./install.sh --interactive
```

The installer will:
1. Check all dependencies
2. Detect platform (Linux/WSL only)
3. Generate config at `~/.config/cc-monitor/config.conf` (permissions 0600)
4. Register hooks in `~/.claude/settings.json` (idempotent)
5. Register cron entries (idempotent)
6. Show a preview and ask for confirmation

### Step 4: Verify installation

```bash
# Test hook mode (should exit cleanly even without tmux)
echo '{"hook_event_name":"SessionEnd"}' | ./cc-monitor.sh hook

# Test watchdog dry-run
./cc-monitor.sh watchdog --dry-run

# Check cron entries
crontab -l | grep cc-monitor

# Check hooks registration
cat ~/.claude/settings.json | jq '.hooks'
```

## Uninstall

```bash
./install.sh --uninstall
```

Removes: hooks from settings.json, cron entries, daemon pidfile. Optionally removes config.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `grep: invalid option -- 'P'` | Install GNU grep: `sudo apt install grep` |
| spinner not detected | Ensure `LC_ALL=C.UTF-8` is set in cron (install.sh does this) |
| WeChat messages not sending | Check openclaw CLI: `openclaw message send --help` |
| DingTalk returns errcode 310000 | Check webhook URL and signing secret |
| Duplicate notifications | Check for duplicate hooks in `~/.claude/settings.json` |
| Watchdog false positives | Ensure no scrollback capture — visible screen only |
