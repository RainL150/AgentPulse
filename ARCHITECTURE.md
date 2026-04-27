# AgentPulse 架构文档

AgentPulse 是一个 macOS 原生应用，用于监控和管理 Claude Code / Codex 会话，提供灵动岛式的交互体验。

## 系统架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        AgentPulse App                            │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │ SessionMon- │  │SocketServer│  │     UI Layer            │  │
│  │ itor        │  │ (Unix Sock) │  │  ┌─────────┐ ┌───────┐  │  │
│  │             │  │             │  │  │IslandVi-│ │Monitor│  │  │
│  │ - sessions  │  │ - pending   │  │  │ew (灵动 │ │View   │  │  │
│  │ - state     │  │   Perms     │  │  │岛)      │ │(面板) │  │  │
│  │ - callbacks │  │ - pending   │  │  └─────────┘ └───────┘  │  │
│  └──────▲──────┘  │   Questions │  └─────────────────────────┘  │
│         │         └──────▲──────┘                                │
├─────────┼────────────────┼──────────────────────────────────────┤
│         │                │           Data Sources               │
│  ┌──────┴──────┐  ┌──────┴──────┐  ┌─────────────┐              │
│  │ JSONLWatch- │  │interaction- │  │ CodexWatch- │              │
│  │ er          │  │bridge.js    │  │ er          │              │
│  │             │  │ (Hook)      │  │             │              │
│  └──────▲──────┘  └──────▲──────┘  └──────▲──────┘              │
└─────────┼────────────────┼────────────────┼─────────────────────┘
          │                │                │
┌─────────┴────────────────┴────────────────┴─────────────────────┐
│                      Claude Code / Codex                         │
│  ~/.claude/tool-flow-logs/calls.jsonl  (工具调用日志)            │
│  ~/.claude/hooks/                       (Hook 脚本)              │
│  ~/.codex/sessions/                     (Codex 会话日志)         │
│  /tmp/agent-pulse.sock                  (Unix Socket)            │
└─────────────────────────────────────────────────────────────────┘
```

## 核心组件

### 1. SessionMonitor (会话监控器)

**文件**: `Sources/SessionMonitor.swift`

单例模式，管理所有会话状态。

```swift
class SessionMonitor: ObservableObject {
    static let shared = SessionMonitor()

    @Published var sessions: [Session] = []
    @Published var activeCount: Int = 0

    // 回调
    var onSessionStopped: ((String) -> Void)?      // 会话中断
    var onSessionCompleted: ((Session, String) -> Void)?  // 会话完成
}
```

**会话状态机**:
```
                    ┌──────────┐
        新请求      │ running  │ ◀─── prompt/tool 事件
        ──────────▶ │  (运行)  │
                    └────┬─────┘
                         │
         ┌───────────────┼───────────────┐
         │ 5分钟无活动   │ stop事件      │
         ▼               ▼               ▼
    ┌─────────┐    ┌──────────┐    ┌──────────┐
    │  idle   │    │ stopped  │    │ expired  │
    │ (空闲)  │    │ (已停止) │    │ (已过期) │
    └─────────┘    └──────────┘    └──────────┘
         │                              ▲
         └──────── 2小时后 ─────────────┘
```

### 2. SocketServer (Unix Socket 服务器)

**文件**: `Sources/Services/SocketServer.swift`

监听 `/tmp/agent-pulse.sock`，接收 Hook 发送的审批和问答请求。

```swift
class SocketServer: ObservableObject {
    @Published var pendingPermissions: [PermissionRequest] = []
    @Published var pendingQuestions: [AskRequest] = []

    func respondPermission(requestId: String, approved: Bool)
    func respondQuestion(requestId: String, answer: String)
    func clearRequestsForSession(_ sessionId: String)
}
```

**请求生命周期**:
1. Hook 发送请求到 Socket
2. SocketServer 解析并存储，保留 fd
3. UI 显示待处理请求
4. 用户操作后发送响应
5. 清理 fd 和请求记录

### 3. JSONLWatcher (日志监听器)

**文件**: `Sources/Services/JSONLWatcher.swift`

使用 `DispatchSource` 监听 JSONL 文件变化。

```swift
class JSONLWatcher {
    init(path: String, onRecord: @escaping (LogRecord) -> Void)
    func start()
    func stop()
}
```

**监听文件**: `~/.claude/tool-flow-logs/calls.jsonl`

**日志格式**:
```json
{"timestamp":"...","session_id":"...","type":"prompt","prompt":"...","cwd":"..."}
{"timestamp":"...","session_id":"...","type":"tool","event":"PostToolUse","tool":"Read","input":{...}}
{"timestamp":"...","session_id":"...","type":"summary","summary":"..."}
{"timestamp":"...","session_id":"...","type":"stop"}
```

### 4. CodexWatcher (Codex 监听器)

**文件**: `Sources/Services/CodexWatcher.swift`

轮询 Codex 会话目录，解析工具调用。

```swift
class CodexWatcher {
    func start()
    func poll()  // 每2秒调用
}
```

**监听目录**: `~/.codex/sessions/`

**工具映射**:
| Codex 命令 | AgentPulse 工具 |
|-----------|----------------|
| exec_command (cat/sed) | Read |
| exec_command (rg/grep) | Grep |
| exec_command (find) | Glob |
| exec_command (git) | Git |
| apply_patch | Edit |
| 其他 exec_command | Bash |

### 5. IslandView (灵动岛视图)

**文件**: `Sources/Views/IslandView.swift`

macOS 灵动岛式浮动窗口。

**三种状态**:
```
┌─────────────────────────────────────┐
│  收起状态 (180×28)                  │
│  ════════════                       │  ← 小胶囊
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│  通知气泡 (360×80)                  │
│  ┌────┐                             │
│  │ ✓  │ AgentPulse                  │  ← 完成通知
│  └────┘ 任务完成描述...      [终端] │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│  展开状态 (520×520)                 │
│  ┌─────────────────────────────┐    │
│  │ 会话列表                    │    │
│  │ ┌───────────────────────┐   │    │
│  │ │ ● session-1  claude   │   │    │  ← 完整面板
│  │ │ ● session-2  codex    │   │    │
│  │ └───────────────────────┘   │    │
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
```

## Hook 系统

### Claude Code Hooks

**配置文件**: `~/.claude/settings.json`

```json
{
  "hooks": {
    "PreToolUse": [...],
    "PostToolUse": [...],
    "PermissionRequest": [...],
    "Stop": [...]
  }
}
```

### interaction-bridge.js

**文件**: `~/.claude/hooks/interaction-bridge.js`

审批和问答的桥接脚本。

**两种模式**:

1. **终端模式** (默认):
   - 发送通知到 AgentPulse
   - 不阻塞，命令行正常显示
   - 用户在终端操作

2. **AgentPulse 模式**:
   - 阻塞等待响应
   - 用户在 AgentPulse 操作
   - 响应后继续执行

**模式切换**: 通过 `~/.claude/hooks/.env` 配置
```
AGENTPULSE_BLOCKING=0  # 终端模式
AGENTPULSE_BLOCKING=1  # AgentPulse 模式
```

### generate-summary.js

**文件**: `~/.claude/hooks/generate-summary.js`

会话结束时生成总结。

**生成流程**:
1. 收集当前会话的工具调用记录
2. 尝试调用 `claude --print` 生成 AI 总结
3. 失败时使用本地规则生成
4. 写入 calls.jsonl

**总结格式**:
```
流程：编译项目 → 修改IslandView.swift → 重启应用
结果：更新 IslandView.swift，完成灵动岛通知功能
```

### log-tools.sh

**文件**: `~/.claude/hooks/log-tools.sh`

记录工具调用到 JSONL 日志。

```bash
#!/bin/bash
# 读取 stdin，解析 hook 数据，写入日志
```

## 数据模型

### Session (会话)

```swift
class Session: Identifiable, ObservableObject {
    let id: String
    var source: SessionAgent      // .claude / .codex
    var state: SessionState       // .running / .idle / .stopped / .expired
    var cwd: String               // 工作目录
    var requests: [UserRequest]   // 用户请求列表
    var tasks: [Task]             // 任务计划
    var lastUpdate: Date
}
```

### UserRequest (用户请求)

```swift
class UserRequest: Identifiable {
    let prompt: String
    let time: Date
    var tools: [ToolCall]         // 工具调用列表
    var summary: Summary?         // AI 总结
}
```

### ToolCall (工具调用)

```swift
struct ToolCall: Identifiable {
    let tool: String              // Read, Edit, Bash, etc.
    let input: [String: Any]
    let time: Date

    var icon: String { ... }      // SF Symbol
    var detail: String { ... }    // 简短描述
    var fullDetail: String { ... } // 完整描述
}
```

## 设置项

**文件**: `Sources/AppSettings.swift`

| 设置 | 说明 | 默认值 |
|-----|------|-------|
| islandEnabled | 启用灵动岛 | true |
| islandAutoExpand | 审批时自动展开 | true |
| islandPlaySound | 播放提示音 | true |
| notifyOnComplete | 任务完成通知 | true |
| islandShowOnNonNotchedDisplays | 非刘海屏显示 | true |
| approvalMode | 审批模式 | .terminal |

## 文件结构

```
AgentPulse/
├── Package.swift
├── Sources/
│   ├── main.swift                 # 入口
│   ├── AgentPulseApp.swift        # AppDelegate
│   ├── AppSettings.swift          # 设置管理
│   ├── IslandOverlayState.swift   # 灵动岛状态
│   ├── Models.swift               # 数据模型
│   ├── SessionMonitor.swift       # 会话监控
│   ├── Services/
│   │   ├── JSONLWatcher.swift     # JSONL 监听
│   │   ├── CodexWatcher.swift     # Codex 监听
│   │   ├── SocketServer.swift     # Unix Socket
│   │   └── TerminalJumper.swift   # 终端跳转
│   └── Views/
│       ├── IslandView.swift       # 灵动岛视图
│       ├── MonitorView.swift      # 面板视图
│       ├── SessionRowView.swift   # 会话行视图
│       └── SettingsView.swift     # 设置视图
└── ARCHITECTURE.md

~/.claude/
├── settings.json                  # Claude Code 配置
├── hooks/
│   ├── .env                       # Hook 环境变量
│   ├── interaction-bridge.js      # 审批桥接
│   ├── generate-summary.js        # 总结生成
│   └── log-tools.sh               # 日志记录
└── tool-flow-logs/
    └── calls.jsonl                # 工具调用日志

/tmp/
└── agent-pulse.sock               # Unix Socket
```

## 构建与运行

```bash
# 开发构建
swift build

# 发布构建
swift build -c release

# 运行
./.build/release/AgentPulse
```

## 依赖

- macOS 13.0+
- Swift 5.9+
- Claude Code 2.x
- Node.js (用于 Hook 脚本)

## 限制与已知问题

1. **Codex 审批**: Codex 使用终端内交互，无法通过 AgentPulse 处理
2. **Hook 超时**: AI 总结生成有 15 秒超时限制
3. **Socket 检测**: 终端操作后约 0.5 秒才能检测到 socket 关闭

## 未来计划

- [ ] 支持更多 AI Agent (Cursor, Windsurf 等)
- [ ] 历史会话搜索
- [ ] 统计面板
- [ ] 快捷键支持
- [ ] 多显示器支持优化
