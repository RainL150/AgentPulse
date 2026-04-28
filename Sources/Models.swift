import Foundation

enum SessionAgent: String {
    case claude
    case codex
    case unknown

    var label: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .unknown: return "unknown"
        }
    }
}

// MARK: - SessionState

enum SessionState: String {
    case running    // 正在执行（有 prompt/tool 事件）
    case idle       // 空闲等待（超时无活动，但没有 stop）
    case stopped    // 主动中断（收到 stop 事件）
    case expired    // 已过期（超过保留时间，待清理）

    var isActive: Bool {
        self == .running
    }

    var icon: String {
        switch self {
        case .running: return "circle.fill"
        case .idle: return "pause.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .expired: return "xmark.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .running: return "green"
        case .idle: return "yellow"
        case .stopped: return "gray"
        case .expired: return "red"
        }
    }

    var label: String {
        switch self {
        case .running: return "运行中"
        case .idle: return "空闲"
        case .stopped: return "已停止"
        case .expired: return "已过期"
        }
    }
}

// MARK: - Session

class Session: Identifiable, ObservableObject {
    let id: String
    @Published var source: SessionAgent = .unknown
    @Published var state: SessionState = .running
    @Published var cwd: String = ""
    @Published var requests: [UserRequest] = []
    @Published var tasks: [Task] = []
    @Published var lastUpdate: Date = Date()

    var currentRequest: UserRequest? { requests.last }
    var activeTaskCount: Int { tasks.filter { $0.status != .completed }.count }

    /// 兼容旧代码的便捷属性
    var isActive: Bool { state.isActive }

    init(id: String) {
        self.id = id
    }
}

// MARK: - UserRequest

class UserRequest: Identifiable, ObservableObject {
    let id = UUID()
    let prompt: String
    let time: Date
    @Published var tools: [ToolCall] = []
    @Published var summary: Summary?

    init(prompt: String, time: Date) {
        self.prompt = prompt
        self.time = time
    }
}

// MARK: - ToolStatus

enum ToolStatus {
    case success
    case failed
    case timeout
}

// MARK: - ToolCall

struct ToolCall: Identifiable {
    let id = UUID()
    let tool: String
    let input: [String: Any]
    let time: Date
    var duration: TimeInterval?  // 执行耗时（秒）
    var status: ToolStatus = .success  // 执行状态

    // 格式化耗时显示
    var durationText: String? {
        guard let d = duration else { return nil }
        if d < 1 {
            return "\(Int(d * 1000))ms"
        } else if d < 60 {
            return String(format: "%.1fs", d)
        } else {
            let mins = Int(d) / 60
            let secs = Int(d) % 60
            return "\(mins)m\(secs)s"
        }
    }

    var icon: String {
        switch tool {
        case "Read": return "doc.text"
        case "Edit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Bash": return "terminal"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder.badge.questionmark"
        case "Task": return "person.2"
        case "Skill": return "sparkles.rectangle.stack"
        case "WebSearch": return "globe"
        case "WebFetch": return "arrow.down.doc"
        case "TaskCreate": return "plus.circle"
        case "TaskUpdate": return "checkmark.circle"
        case "Git": return "arrow.triangle.branch"
        default: return "wrench"
        }
    }

    var detail: String {
        if let path = input["file_path"] as? String {
            return (path as NSString).lastPathComponent
        }
        // 支持 Claude Code 的 command 和 Codex 的 cmd
        if let cmd = input["command"] as? String ?? input["cmd"] as? String {
            return String(cmd.prefix(40))
        }
        if let query = input["query"] as? String {
            return String(query.prefix(30))
        }
        if let skill = input["skill"] as? String {
            return "/\(skill)"
        }
        if let subagentType = input["subagent_type"] as? String {
            return "[\(subagentType)]"
        }
        // Codex apply_patch
        if input["patch"] != nil {
            if let path = input["file_path"] as? String {
                return (path as NSString).lastPathComponent
            }
            return "patch..."
        }
        return ""
    }

    var fullDetail: String {
        switch tool {
        case "Read":
            if let path = input["file_path"] as? String {
                // 显示相对路径或最后两级
                let components = path.split(separator: "/")
                if components.count > 2 {
                    return ".../" + components.suffix(2).joined(separator: "/")
                }
                return path
            }
        case "Edit":
            if let path = input["file_path"] as? String {
                let file = (path as NSString).lastPathComponent
                if let oldStr = input["old_string"] as? String {
                    let preview = oldStr.prefix(20).replacingOccurrences(of: "\n", with: " ")
                    return "\(file): \"\(preview)...\""
                }
                return file
            }
        case "Write":
            if let path = input["file_path"] as? String {
                return (path as NSString).lastPathComponent
            }
        case "Bash":
            if let desc = input["description"] as? String {
                return desc
            }
            // 支持 Claude Code 的 command 和 Codex 的 cmd
            if let cmd = input["command"] as? String ?? input["cmd"] as? String {
                return String(cmd.prefix(80))
            }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                let path = input["path"] as? String ?? ""
                let dir = (path as NSString).lastPathComponent
                return "\"\(pattern)\" in \(dir.isEmpty ? "." : dir)"
            }
        case "Glob":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "WebSearch":
            if let query = input["query"] as? String {
                return "\"\(query)\""
            }
        case "WebFetch":
            if let url = input["url"] as? String {
                return url.replacingOccurrences(of: "https://", with: "").prefix(50).description
            }
        case "TaskCreate":
            if let subject = input["subject"] as? String {
                return "创建: \(subject)"
            }
        case "TaskUpdate":
            if let taskId = input["taskId"] as? String,
               let status = input["status"] as? String {
                return "#\(taskId) → \(status)"
            }
        case "AskUserQuestion":
            // 提取并显示问题内容
            if let questions = input["questions"] as? [[String: Any]],
               let firstQ = questions.first,
               let question = firstQ["question"] as? String {
                return "❓ \(question)"
            }
            return "等待用户回答..."
        case "Task":
            // 显示子代理类型和描述
            let agentType = input["subagent_type"] as? String ?? ""
            let desc = input["description"] as? String ?? ""
            if !agentType.isEmpty && !desc.isEmpty {
                return "[\(agentType)] \(desc)"
            } else if !agentType.isEmpty {
                return "[\(agentType)]"
            } else if !desc.isEmpty {
                return desc
            }
            if let prompt = input["prompt"] as? String {
                return String(prompt.prefix(50))
            }
        case "Skill":
            // 显示 skill 名称和参数
            let skillName = input["skill"] as? String ?? ""
            let args = input["args"] as? String ?? ""
            if !skillName.isEmpty {
                if !args.isEmpty {
                    return "/\(skillName) \(args)"
                }
                return "/\(skillName)"
            }
        default:
            break
        }
        return detail
    }
}

// MARK: - Task

struct Task: Identifiable {
    let id: String
    var subject: String
    var status: TaskStatus
    var activeForm: String?

    var statusIcon: String {
        switch status {
        case .pending: return "○"
        case .inProgress: return "◐"
        case .completed: return "✓"
        }
    }
}

enum TaskStatus: String {
    case pending
    case inProgress = "in_progress"
    case completed
}

// MARK: - Summary

struct Summary {
    let flow: String
    let result: String

    init?(raw: String) {
        let lines = raw.split(separator: "\n").map(String.init)
        var flowText: String?
        var resultText: String?

        for line in lines {
            if line.hasPrefix("流程") {
                flowText = line.replacingOccurrences(of: "^流程[：:]\\s*", with: "", options: .regularExpression)
            } else if line.hasPrefix("结果") {
                resultText = line.replacingOccurrences(of: "^结果[：:]\\s*", with: "", options: .regularExpression)
            }
        }

        guard let flow = flowText, let result = resultText else {
            // 非结构化格式，整体作为结果
            if !raw.isEmpty {
                self.flow = ""
                self.result = raw
                return
            }
            return nil
        }

        self.flow = flow
        self.result = result
    }
}

// MARK: - PermissionRequest

struct PermissionRequest: Identifiable {
    let id: String
    let sessionId: String
    let tool: String
    let input: [String: Any]
    let timestamp: Date

    var icon: String {
        switch tool {
        case "Bash": return "terminal"
        case "Edit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Read": return "doc.text"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder.badge.questionmark"
        case "Task": return "person.2"
        case "WebSearch": return "globe"
        case "WebFetch": return "arrow.down.doc"
        case "AskUserQuestion": return "questionmark.bubble.fill"
        default: return "wrench"
        }
    }

    var summary: String {
        switch tool {
        case "Bash":
            if let desc = input["description"] as? String {
                return desc
            }
            // 支持 Claude Code 的 command 和 Codex 的 cmd
            if let cmd = input["command"] as? String ?? input["cmd"] as? String {
                return String(cmd.prefix(60))
            }
        case "Edit":
            if let path = input["file_path"] as? String {
                return "编辑 \((path as NSString).lastPathComponent)"
            }
        case "Write":
            if let path = input["file_path"] as? String {
                return "写入 \((path as NSString).lastPathComponent)"
            }
        case "Read":
            if let path = input["file_path"] as? String {
                return "读取 \((path as NSString).lastPathComponent)"
            }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                return "搜索 \"\(pattern)\""
            }
        case "WebSearch":
            if let query = input["query"] as? String {
                return "搜索 \"\(query)\""
            }
        case "Task":
            if let desc = input["description"] as? String {
                return "子任务: \(desc)"
            }
        case "AskUserQuestion":
            // 提取问题内容
            if let questions = input["questions"] as? [[String: Any]],
               let firstQ = questions.first,
               let question = firstQ["question"] as? String {
                return question
            }
            return "等待用户回答"
        default:
            break
        }
        return tool
    }

    var detail: String {
        // detail 只显示 summary 中没有的补充信息，避免重复
        switch tool {
        case "Bash":
            // summary 已显示 description，detail 只显示命令
            // 支持 Claude Code 的 command 和 Codex 的 cmd
            if let cmd = input["command"] as? String ?? input["cmd"] as? String {
                return cmd
            }
        case "Edit":
            // summary 显示文件名，detail 显示完整路径和替换内容
            var parts: [String] = []
            if let path = input["file_path"] as? String {
                parts.append(path)
            }
            if let oldStr = input["old_string"] as? String {
                let preview = oldStr.prefix(80).replacingOccurrences(of: "\n", with: "↵")
                parts.append("替换: \"\(preview)\"")
            }
            return parts.joined(separator: "\n")
        case "Write":
            // summary 显示文件名，detail 显示完整路径
            if let path = input["file_path"] as? String {
                return path
            }
        case "Read":
            // summary 显示文件名，detail 显示完整路径
            if let path = input["file_path"] as? String {
                return path
            }
        case "Grep":
            // summary 显示模式，detail 显示路径
            if let path = input["path"] as? String {
                return "路径: \(path)"
            }
        case "Task":
            // summary 显示描述，detail 显示任务详情
            if let prompt = input["prompt"] as? String {
                return String(prompt.prefix(300))
            }
        case "AskUserQuestion":
            // 显示选项
            if let questions = input["questions"] as? [[String: Any]],
               let firstQ = questions.first,
               let options = firstQ["options"] as? [[String: Any]] {
                let labels = options.compactMap { $0["label"] as? String }
                return "选项: " + labels.joined(separator: " | ")
            }
        default:
            break
        }

        return ""
    }

    var fullInput: String {
        // 返回完整的 input JSON 用于详情展示
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return ""
    }
}

// MARK: - AskRequest

struct AskRequest: Identifiable {
    let id: String
    let sessionId: String
    let questions: [[String: Any]]
    let timestamp: Date

    var firstQuestion: String {
        if let q = questions.first?["question"] as? String {
            return q
        }
        return "问题"
    }

    var options: [String] {
        guard let opts = questions.first?["options"] as? [[String: Any]] else { return [] }
        return opts.compactMap { $0["label"] as? String }
    }
}

// MARK: - LogRecord

struct LogRecord {
    let timestamp: Date
    let sessionId: String
    let type: String
    let event: String?
    let tool: String?
    let input: [String: Any]?
    let prompt: String?
    let summary: String?
    let cwd: String?

    init?(json: [String: Any]) {
        guard let ts = json["timestamp"] as? String,
              let sid = json["session_id"] as? String,
              let type = json["type"] as? String else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestamp = formatter.date(from: ts) ?? Date()
        self.sessionId = sid
        self.type = type
        self.event = json["event"] as? String
        self.tool = json["tool"] as? String
        self.input = json["input"] as? [String: Any]
        self.prompt = json["prompt"] as? String
        self.summary = json["summary"] as? String
        self.cwd = json["cwd"] as? String
    }
}
