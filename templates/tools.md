<!-- cc-monitor-managed: workspace-template v1 -->
# TOOLS.md — Toolbox

## Configuration

Read `cc-monitor.workspace.json` in your workspace root. It contains:

- `ccMonitorDir` — where cc-monitor is installed
- `configPath` — cc-monitor config file path
- `markerDir` — where marker files are stored
- `channelId` — the OpenClaw channel (e.g. `openclaw-weixin` for WeChat, `feishu` for Feishu)
- `agentName` — your agent name in OpenClaw

For channel-specific values (target, account), read the config file at `configPath`. Check whichever section is enabled: `[channel:wechat]` (WeChat) or `[channel:feishu-openclaw]` (Feishu).

## tmux Rules

1. **Never kill** tmux sessions
2. Use `paste-buffer` for text input (handles special characters, bracketed paste protocol)
3. Text and `Enter` are **always separate** operations
4. If a session doesn't exist, tell the user — don't create it
5. Gray prompt text is not real user input — don't press Enter for it

### Relay a message

```
1. Write marker file to {markerDir}/{session}.json
2. tmux set-buffer "message text"
3. tmux paste-buffer -t <session>
4. sleep briefly
5. tmux send-keys -t <session> Enter
```

The marker file tells cc-monitor hooks where to send notifications (the `target` field). Without it, the monitoring system won't know how to reach the user when the task completes or fails.

### Check a session

```bash
tmux capture-pane -t <session> -p | tail -40
```

For scrollback:

```bash
tmux capture-pane -t <session> -p -S -200
```

## Monitoring Hooks

After you relay a message, cc-monitor's hooks take over automatically:

| Event | Hook behavior |
|-------|--------------|
| Task completes | Sends completion summary to user, cleans up marker |
| API error | Auto-retries with exponential backoff (up to 5x) |
| Permission request | Safe tools auto-approved; others notify user then auto-approve after timeout |
| Quota exceeded | Detects reset time, suppresses retry until quota resets |
| Session ends | Cleans up marker file |
| Session stuck | Watchdog (cron) detects frozen sessions and recovers them |

Debug logs go to `{markerDir}/debug/`. Kept to last 20 files automatically.

You don't need to track monitoring state — just relay and let the hooks handle the rest.
