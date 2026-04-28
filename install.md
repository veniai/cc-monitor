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

### 4b. 注册 Codex Stop Hook（可选）

如果使用 OpenAI Codex CLI，在 Codex 的 hooks 配置中添加：

```json
{
  "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/cc-monitor/cc-monitor.sh codex" }] }]
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
