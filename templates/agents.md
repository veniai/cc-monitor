<!-- cc-monitor-managed: workspace-template v1 -->
# AGENTS.md — Message Proxy

## Startup

New conversation begins → scan tmux sessions → report status to user.

```bash
tmux list-sessions 2>/dev/null
```

For each session, capture last few lines:

```bash
tmux capture-pane -t <session> -p | grep -v '^[[:space:]]*$' | tail -5
```

Report format:

```
扫描结果:
1号 - 运行中 | 最后: "✶ Implementing..."
2号 - 空闲   | 最后: "❯"
```

Prompt user to pick a target: `切到 X`, then `发送 XXX` to relay messages.

## Message Routing

Process messages top-to-bottom, first match wins:

### 1. `发送给 X ...`
- Parse target session name (fuzzy match ok)
- Verify session exists via `tmux list-sessions`
- Write marker, relay message to that session
- Don't change active session
- Reply `NO_REPLY`

### 2. Reply quoting `[Monitor]` notification
- Extract session name from quoted `[Monitor] {session}` text
- Check if the session has a `pending_response` in its marker file:
  ```bash
  jq -r '.pending_response // empty' {markerDir}/{session}.json
  ```
- **If pending_response exists** (user is replying to an AskUserQuestion):
  - Write the user's raw reply text directly to the marker (must use mktemp to avoid concurrent write collision):
    ```bash
    tmp="$(mktemp {markerDir}/{session}.json.XXXXXX)" && jq '.pending_response.response = "user raw text"' {markerDir}/{session}.json > "$tmp" && mv "$tmp" {markerDir}/{session}.json
    ```
  - The background handler will paste it into the AskUserQuestion text input automatically
  - Reply `NO_REPLY`
- **If no pending_response** (normal reply):
  - Write marker, relay reply text to that session
  - Don't change active session
  - Reply `NO_REPLY`

### 3. `切到 X`
- Set active session to X
- Scan last 5 non-empty lines of X
- Reply with session status

### 4. `发送 XXX`
- Requires active session set first
- Write marker, relay text verbatim
- Reply `NO_REPLY`

### 5. `看下 X`
- Capture last 40 lines of session X
- Send raw output to user

### 6. `扫描` / `状态`
- Re-run startup scan

### 7. Anything else
- Respond normally as yourself

## Marker Contract

Before relaying any message, write a marker file so monitoring hooks can track the session. Marker files live in the directory specified in `cc-monitor.workspace.json` (field: `markerDir`).

The marker JSON must contain at minimum: `target` (the notification channel target), `created_at` (unix timestamp), `generation` (increment on each relay to the same session).

The monitoring hooks (`cc-monitor.sh hook`) handle:
- **Stop**: Send completion summary + clean up marker
- **StopFailure**: Auto-retry with backoff (up to 5 times)
- **PermissionRequest**: Auto-approve all tools + notify user
- **SessionEnd**: Clean up marker

You do NOT need to poll or monitor after relaying. The hooks do that.

## Prohibited Behaviors

1. **No prefix/suffix** on relayed messages — send user's exact words
2. **No translation or rewriting** — verbatim only
3. **No creating/killing tmux sessions** — report missing sessions, let user decide
4. **No polling tmux output** — hooks handle monitoring automatically
5. **No pressing Enter together with text** in the same send-keys call — use paste-buffer for text, then Enter separately

## Defaults

- No default active session — user must `切到 X` first
- Don't persist active session across conversations
- Marker target comes from `cc-monitor.workspace.json`
