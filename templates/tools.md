<!-- cc-monitor-managed: workspace-template v2 -->
# TOOLS.md - Dev Agent Toolbox

## 配置

读 workspace 根目录的 `cc-monitor.workspace.json`，包含：

- `ccMonitorDir` — cc-monitor 安装目录
- `configPath` — 配置文件路径
- `markerDir` — marker 文件目录
- `channelId` — OpenClaw 通道（如 `openclaw-weixin`）
- `agentName` — agent 名称

通道相关值（target, account）从 `configPath` 配置文件读取，看对应 section：`[channel:wechat]` 或 `[channel:feishu-openclaw]`。

## tmux 铁律

- 永远不要 kill tmux session
- 你只负责 `paste-buffer`、`send-keys`（仅用于 Enter/Escape）和 `capture-pane`
- session 不存在时告诉用户，不要自作主张创建
- 灰色提示词不是用户输入，不要替用户按 Enter

## 开局扫描

```bash
tmux list-sessions 2>/dev/null
tmux capture-pane -t <session> -p | grep -v '^[[:space:]]*$' | tail -5
```

## 转发消息

先写 marker，再发消息。marker 写到 `{markerDir}/`。

```bash
mkdir -p {markerDir}
GEN=$(jq -r '.generation // 0' {markerDir}/<session>.json 2>/dev/null || echo 0)
cat > {markerDir}/<session>.json <<EOF
{"target":"<从config读对应channel的openclaw_target>","created_at":$(date +%s),"auto_resume_count":0,"last_retry_at":0,"generation":$((GEN + 1))}
EOF
tmux set-buffer "消息内容"
tmux paste-buffer -t <session>
sleep 1
tmux send-keys -t <session> Enter
```

规则：

- 用 `paste-buffer` 发送文本（触发 bracketed paste 协议，Codex CLI 不会误判 Enter 为换行）
- 文字和 `Enter` 分开发送
- marker 里的 `target` 告诉 cc-monitor hooks 往哪发通知，不写这个 monitor 就找不到用户

## 查看状态

```bash
tmux capture-pane -t <session> -p | tail -40
tmux capture-pane -t <session> -p -S -200
```

## Hook 监控

转发后由 cc-monitor hooks 自动处理，你不需要轮询：

| 事件 | 行为 |
|------|------|
| 任务完成 | 发送完成摘要 + 清理 marker |
| API 错误 | 自动退避重试，最多 5 次 |
| 权限请求 | 安全工具静默批准；其他工具立即批准后通知用户 |
| 提问 (AskUserQuestion) | 立即放行，通知用户问题和选项，轮询 marker 等用户回复（无超时，必须用户作答） |
| 限额满 | 检测重置时间，等待后自动恢复 |
| 会话卡住 | Watchdog 检测并自动恢复 |

- 标记文件：`{markerDir}/<session>.json`
- 调试日志：`{markerDir}/debug/`，自动保留最近 20 个

你不需要自己跟踪监控状态。转发完就走，hooks 会处理剩下的事。
