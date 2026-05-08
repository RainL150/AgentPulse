# AgentPulse

macOS 灵动岛风格应用，实时监控 Claude Code / Codex 执行状态。

<img width="560" height="600" alt="image" src="https://github.com/user-attachments/assets/6c72d82f-1b80-4926-9c80-ccb544be29b0" />

<img width="560" height="389" alt="image" src="https://github.com/user-attachments/assets/9cb7ae88-379c-45d4-adf1-d7f5021982e6" />

<img width="440" height="188" alt="image" src="https://github.com/user-attachments/assets/52f60f99-6578-4771-9881-1cc320ffea26" />

## 功能

- **灵动岛 UI** - 悬浮窗口，悬停展开，自动收起
- **双引擎支持** - 同时监控 Claude Code 和 Codex 会话
- **实时状态** - 6 态系统：运行中(绿)、待审批(橙)、完成(蓝)、中断(红)、空闲(黄)、过期(灰)
- **权限审批** - 灵动岛内直接批准/拒绝工具请求
- **问题回复** - 直接回答 AskUserQuestion 提问
- **执行流水** - 可视化工具调用链，支持展开/折叠
- **任务计划** - 显示 TaskCreate/TaskUpdate 创建的任务列表
- **完成通知** - 会话完成时弹出通知，显示 AI 总结
- **终端跳转** - 一键跳转到对应 iTerm2/Terminal 标签页
- **会话持久化** - 重启后恢复会话状态

## 会话状态

| 状态 | 颜色 | 说明 |
|------|------|------|
| running | 🟢 绿色 | 正在执行 |
| waiting | 🟠 橙色 | 待审批/提问 |
| completed | 🔵 蓝色 | 正常完成 |
| stopped | 🔴 红色 | 被打断 |
| idle | 🟡 黄色 | 空闲 (5分钟无活动) |
| expired | ⚪ 浅灰 | 过期 (2小时) |

## 架构

```
Claude Code (hooks)              Codex (~/.codex/)
    │                                │
    ├─ log-tools.sh ────────┐       │
    ├─ generate-summary.js ─┤       │
    └─ interaction-bridge.js┤       │
                            │       │
                            ▼       ▼
                      Swift 灵动岛 App
                      ├─ JSONLWatcher (FSEvents)
                      ├─ CodexWatcher (Polling)
                      ├─ SocketServer (Unix Socket)
                      ├─ SessionMonitor (状态管理)
                      └─ TerminalJumper (AppleScript)
```

## 构建

```bash
# 需要 Swift 5.9+
./build.sh

# 或手动构建
swift build -c release
```

## 运行

```bash
# 方式 1: 双击 app
open /Applications/AgentPulse.app

# 方式 2: 命令行
.build/release/AgentPulse
```

## 配置 Hooks

确保 `~/.claude/settings.json` 包含以下 hooks：

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "type": "command", "command": "/Users/YOU/.claude/hooks/log-tools.sh" }
    ],
    "PreToolUse": [
      { "type": "command", "command": "/Users/YOU/.claude/hooks/log-tools.sh" }
    ],
    "PostToolUse": [
      { "type": "command", "command": "/Users/YOU/.claude/hooks/log-tools.sh" }
    ],
    "Stop": [
      { "type": "command", "command": "/Users/YOU/.claude/hooks/log-tools.sh" },
      { "type": "command", "command": "node /Users/YOU/.claude/hooks/generate-summary.js" }
    ],
    "PermissionRequest": [
      { "type": "command", "command": "node /Users/YOU/.claude/hooks/interaction-bridge.js" }
    ],
    "PreToolUse[AskUserQuestion]": [
      { "type": "command", "command": "node /Users/YOU/.claude/hooks/interaction-bridge.js" }
    ]
  }
}
```

## 文件说明

```
AgentPulse/
├── Package.swift              # Swift 包定义
├── build.sh                   # 构建脚本
├── Sources/
│   ├── AgentPulseApp.swift    # 应用入口
│   ├── Models.swift           # 数据模型 (Session, ToolCall, Task...)
│   ├── SessionMonitor.swift   # 状态管理
│   ├── IslandOverlayState.swift # 灵动岛状态
│   ├── Info.plist             # App 配置
│   ├── Views/
│   │   ├── IslandView.swift       # 灵动岛主视图
│   │   ├── MonitorView.swift      # 传统面板
│   │   └── SessionRowView.swift   # 会话行组件
│   └── Services/
│       ├── JSONLWatcher.swift     # Claude Code 日志监听
│       ├── CodexWatcher.swift     # Codex 会话监听
│       ├── SocketServer.swift     # Unix Socket 服务
│       ├── SessionPersistence.swift # 会话持久化
│       └── TerminalJumper.swift   # 终端跳转
```

## TODO

- [ ] 中断状态检测优化 (Claude Code 不传递 stop_reason)
- [ ] Token 用量统计
- [ ] 快捷键支持
- [ ] 多显示器支持
