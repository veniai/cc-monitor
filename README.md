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
