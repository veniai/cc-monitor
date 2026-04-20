# cc-monitor

Remote monitoring and input tool for [Claude Code](https://claude.ai/code). Get notified when tasks complete, auto-recover stuck sessions, and send commands from your phone via WeChat, DingTalk, or Feishu.

```
  Your Computer (tmux)                    Your Phone
┌─────────────────────┐              ┌──────────────────┐
│  ✶ Refactoring…     │─── notify ──▶│ "2号 任务完成:"   │
│  (Claude working)    │              │ "重构登录模块..."  │
│                      │◀── command ──│ "@1号 继续"       │
└─────────────────────┘              └──────────────────┘
```

## Features

- **Task notifications** — Get WeChat/DingTalk/Feishu messages when Claude Code finishes, hits errors, or requests permissions
- **Stuck detection** — Watchdog monitors spinner state and auto-recovers frozen sessions
- **Remote input** — Send commands like `@session 继续` or `@session 停止` from your IM client
- **Permission handling** — Auto-approve safe tools, notify + delay-approve risky ones
- **Plugin channels** — Add new notification channels by dropping a `.sh` file

## Quick Start

### Option A: AI-driven install

Tell your Claude Code:

```
请按照 https://github.com/veniai/cc-monitor/blob/main/install.md 安装 cc-monitor
```

### Option B: Manual install

```bash
git clone https://github.com/veniai/cc-monitor.git
cd cc-monitor

# Interactive setup
./install.sh --interactive

# Or non-interactive
./install.sh --channel wechat --enable-watchdog
```

## Prerequisites

- **Claude Code** (the CLI tool)
- **tmux** — terminal multiplexer
- **jq** — JSON processor
- **grep -P** — Perl regex support (GNU grep)
- **bash 4+**
- **python3** (optional, for DingTalk signing)
- **openclaw** CLI (optional, for WeChat channel)

Platform: **Linux** or **WSL** (Windows Subsystem for Linux). macOS has known compatibility issues (see below).

## Configuration

Copy `config.example.conf` to `~/.config/cc-monitor/config.conf`:

```ini
[monitor]
watchdog_interval=300
auto_recovery_max=2

[channel:wechat]
enabled=true
account=your-openclaw-account-id
target=your-target@im.wechat

[channel:dingtalk]
enabled=false
webhook=https://oapi.dingtalk.com/robot/send?access_token=xxx
secret=

[channel:feishu]
enabled=false
webhook=https://open.feishu.cn/open-apis/bot/v2/hook/xxx

[input:wechat]
enabled=false
poll_interval=30
allowed_commands=继续,continue,停止,stop,状态,status
allowed_senders=
rate_limit_per_minute=10
```

Environment variable override: `CC_MONITOR_<SECTION>_<KEY>` (e.g., `CC_MONITOR_CHANNEL_DINGTALK_WEBHOOK`).

## Channel Setup

### WeChat (via OpenClaw)

1. Install OpenClaw: `pip install openclaw`
2. Run `openclaw login`
3. Get `account`: `openclaw account list`
4. Get `target`: `openclaw contact list` (format: `id@im.wechat`)

### DingTalk

1. DingTalk Group → Settings → Smart Group Assistant → Add Robot → Custom
2. Copy the webhook URL
3. Optionally enable signing and copy the secret

### Feishu / Lark

1. Feishu Group → Settings → Bots → Add Bot → Custom Bot
2. Copy the webhook URL
3. Optionally configure signing key

## Usage

cc-monitor runs in three modes:

### Hook mode (automatic)

Registered as Claude Code hooks — fires on task events:

```bash
# Registered automatically by install.sh
# Triggers: Stop, StopFailure, PermissionRequest, SessionEnd
```

### Watchdog mode (cron)

Checks for stuck sessions every 5 minutes:

```bash
# Added to crontab by install.sh
# Or run manually:
./cc-monitor.sh watchdog
./cc-monitor.sh watchdog --dry-run  # preview only
```

### Remote Input mode (daemon)

Polls IM for commands:

```bash
./cc-monitor.sh remote-input          # start daemon
./cc-monitor.sh remote-input --stop   # stop daemon
```

Send from WeChat:
- `@session名 继续` — resume a stuck session
- `@session名 停止` — stop a session
- `状态` — get status of all sessions

## Architecture

```
cc-monitor.sh           # Single entry point
├── lib/
│   ├── config.sh       # Config loader (INI + env var override)
│   ├── hooks.sh        # CC hook handlers
│   ├── watchdog.sh     # Stuck session detection
│   ├── tmux.sh         # tmux utilities
│   ├── notify.sh       # Notification dispatcher
│   ├── marker.sh       # Session state files
│   └── remote-input.sh # Command parsing + security + daemon
├── channels/           # Outbound notification plugins
│   ├── wechat.sh       # WeChat via OpenClaw CLI
│   ├── dingtalk.sh     # DingTalk webhook
│   ├── feishu.sh       # Feishu webhook
│   └── _template.sh    # Template for new channels
└── inputs/             # Inbound message plugins
    ├── wechat.sh       # WeChat message polling
    └── _template.sh    # Template for new inputs
```

### Adding a new channel

1. Copy `channels/_template.sh` to `channels/yourchannel.sh`
2. Implement `channel_send()` function
3. Add `[channel:yourchannel]` section to config
4. Done — notify.sh auto-discovers new channels

## Platform Support

| Platform | Status |
|----------|--------|
| Linux (Ubuntu/Debian) | Fully supported |
| WSL (Windows) | Fully supported |
| macOS | Partial — `grep -P`, `flock`, `md5sum` unavailable by default. Install GNU tools via Homebrew. |
| Windows native | Not supported (requires tmux) |

## Related Projects

- **[codesop](https://github.com/veniai/codesop)** — AI Coding SOP for structured development workflows with Claude Code
- **[Claude-to-IM](https://github.com/veniai/Claude-to-IM-skill)** — Bridge Claude Code to IM platforms

## License

[MIT](LICENSE)
