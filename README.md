# AgentPulse

macOS 菜单栏应用，实时监控 Claude Code 执行状态。

## 功能

- **实时监控** - 菜单栏显示活跃会话数，点击展开详情
- **会话管理** - 查看多个 Claude Code 会话的状态
- **执行流水** - 可视化工具调用链
- **任务计划** - 显示 TaskCreate/TaskUpdate 创建的任务列表
- **AI 总结** - 展示结构化的流程+结果总结
- **终端跳转** - 一键跳转到对应 iTerm2/Terminal 标签页
- **权限通知** - 工具请求权限时弹出系统通知（规划中）

## 架构

```
Claude Code (hooks)
    │
    ├─ log-tools.sh ──────→ ~/.claude/tool-flow-logs/calls.jsonl
    ├─ generate-summary.js ─→ AI 生成执行总结
    └─ permission-bridge.js ─→ /tmp/agent-pulse.sock
                                    │
                                    ▼
                            Swift 菜单栏 App
                            ├─ JSONLWatcher (FSEvents)
                            ├─ SocketServer (Unix Socket)
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
      { "type": "command", "command": "node /Users/YOU/.claude/hooks/permission-bridge.js" }
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
│   ├── Models.swift           # 数据模型
│   ├── SessionMonitor.swift   # 状态管理
│   ├── Info.plist             # App 配置
│   ├── Views/
│   │   ├── MonitorView.swift      # 主面板
│   │   └── SessionRowView.swift   # 会话详情
│   └── Services/
│       ├── JSONLWatcher.swift     # 日志监听
│       ├── SocketServer.swift     # Socket 服务
│       └── TerminalJumper.swift   # 终端跳转
```

## TODO

- [ ] 权限审批交互（Approve/Deny 按钮）
- [ ] AskUserQuestion 直接回复
- [ ] 多 Agent 并行监控
- [ ] 历史记录持久化
- [ ] 快捷键支持
