# cc-monitor

[Claude Code](https://claude.ai/code) 远程监控与输入工具。任务完成时收到通知、自动恢复卡住的会话、从手机通过微信/钉钉/飞书发送指令。

```
  你的电脑 (tmux)                         你的手机
┌─────────────────────┐              ┌──────────────────┐
│  ✶ 重构登录模块…     │─── 通知 ────▶│ "2号 任务完成:"   │
│  (Claude 在跑)       │              │ "已完成重构..."    │
│                      │◀── 远程输入 ─│ "@1号 继续"       │
└─────────────────────┘              └──────────────────┘
```

## 功能

- **任务通知** — Claude Code 完成、出错、请求权限时，通过微信/钉钉/飞书推送消息
- **卡住检测** — Watchdog 监控 spinner 状态，自动恢复卡死的会话
- **远程输入** — 从 IM 发送 `@session 继续` 或 `@session 停止`
- **权限处理** — 安全工具自动批准，风险工具通知 + 延迟批准
- **插件式渠道** — 放一个 `.sh` 文件就能添加新通知渠道

## 快速开始

### 方式 A：AI 驱动安装

告诉你的 Claude Code：

```
请按照 https://github.com/veniai/cc-monitor/blob/main/install.md 安装 cc-monitor
```

### 方式 B：手动安装

```bash
git clone https://github.com/veniai/cc-monitor.git
cd cc-monitor

# 交互式安装
./install.sh --interactive

# 或非交互式
./install.sh --channel wechat --enable-watchdog
```

## 前置依赖

- **Claude Code**（CLI 工具）
- **tmux** — 终端复用器
- **jq** — JSON 处理器
- **grep -P** — Perl 正则（GNU grep）
- **bash 4+**
- **python3**（可选，钉钉加签需要）
- **openclaw** CLI（可选，微信渠道需要）

平台：**Linux** 或 **WSL**。macOS 有兼容性问题（见下方说明）。

## 配置

复制 `config.example.conf` 到 `~/.config/cc-monitor/config.conf`：

```ini
[monitor]
watchdog_interval=300
auto_recovery_max=2

[channel:wechat]
enabled=true
account=你的openclaw-account-id
target=你的target@im.wechat

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

环境变量覆盖：`CC_MONITOR_<SECTION>_<KEY>`（如 `CC_MONITOR_CHANNEL_DINGTALK_WEBHOOK`）。

## 渠道配置

### 微信（via OpenClaw）

1. 安装 OpenClaw：`pip install openclaw`
2. 运行 `openclaw login`
3. 获取 `account`：`openclaw account list`
4. 获取 `target`：`openclaw contact list`（格式：`id@im.wechat`）

### 钉钉

1. 钉钉群 → 设置 → 智能群助手 → 添加机器人 → 自定义
2. 复制 webhook URL
3. 可选：开启加签，复制 secret

### 飞书

1. 飞书群 → 设置 → 群机器人 → 添加机器人 → 自定义机器人
2. 复制 webhook URL
3. 可选：配置签名密钥

## 使用方式

### Hook 模式（自动触发）

注册为 Claude Code hooks —— 任务事件时自动触发：

```bash
# 由 install.sh 自动注册
# 触发事件：Stop, StopFailure, PermissionRequest, SessionEnd
```

### Watchdog 模式（定时检查）

每 5 分钟检查是否有卡住的会话：

```bash
# 由 install.sh 添加到 crontab
# 或手动运行：
./cc-monitor.sh watchdog
./cc-monitor.sh watchdog --dry-run  # 仅预览
```

### 远程输入模式（守护进程）

轮询 IM 接收命令：

```bash
./cc-monitor.sh remote-input          # 启动
./cc-monitor.sh remote-input --stop   # 停止
```

从微信发送：
- `@session名 继续` — 恢复卡住的会话
- `@session名 停止` — 停止会话
- `状态` — 查看所有会话状态

## 架构

```
cc-monitor.sh           # 唯一入口
├── lib/
│   ├── config.sh       # 配置加载（INI + 环境变量覆盖）
│   ├── hooks.sh        # CC hook 处理器
│   ├── watchdog.sh     # 卡住检测
│   ├── tmux.sh         # tmux 工具函数
│   ├── notify.sh       # 通知分发
│   ├── marker.sh       # 会话状态文件
│   └── remote-input.sh # 命令解析 + 安全 + 守护进程
├── channels/           # 出站通知插件
│   ├── wechat.sh       # 微信（openclaw CLI）
│   ├── dingtalk.sh     # 钉钉（webhook）
│   ├── feishu.sh       # 飞书（webhook）
│   └── _template.sh    # 新渠道模板
└── inputs/             # 入站消息插件
    ├── wechat.sh       # 微信消息轮询
    └── _template.sh    # 新输入源模板
```

### 添加新渠道

1. 复制 `channels/_template.sh` 到 `channels/你的渠道.sh`
2. 实现 `channel_send()` 函数
3. 在配置文件中添加 `[channel:你的渠道]` section
4. 完成 —— notify.sh 会自动发现新渠道

## 平台支持

| 平台 | 状态 |
|------|------|
| Linux (Ubuntu/Debian) | 完全支持 |
| WSL (Windows) | 完全支持 |
| macOS | 部分 —— 缺少 `grep -P`、`flock`、`md5sum`。可通过 Homebrew 安装 GNU 工具解决。 |
| Windows 原生 | 不支持（依赖 tmux） |

## 相关项目

- **[codesop](https://github.com/veniai/codesop)** — AI 编码 SOP，Claude Code 结构化开发工作流
- **[Claude-to-IM](https://github.com/veniai/Claude-to-IM-skill)** — Claude Code 桥接到 IM 平台

## 许可证

[MIT](LICENSE)
