import Foundation

final class CodexWatcher {
    private let historyPath: String
    private let sessionsRoot: String
    private let monitor: SessionMonitor
    private let recentWindow: TimeInterval = 60 * 60 * 12
    private let minimumPollInterval: TimeInterval = 10
    private var lastPollAt: Date = .distantPast

    private var processedPromptKeys: Set<String> = []
    private var processedCallIds: Set<String> = []
    private var processedSummaryKeys: Set<String> = []
    private var processedMessageKeys: Set<String> = []
    private var sessionCwds: [String: String] = [:]
    private var sessionFiles: [String: String] = [:]
    private var fileLineOffsets: [String: Int] = [:]
    private var fileModifiedAt: [String: Date] = [:]
    private var historyModifiedAt: Date = .distantPast

    init(
        monitor: SessionMonitor,
        historyPath: String = NSHomeDirectory() + "/.codex/history.jsonl",
        sessionsRoot: String = NSHomeDirectory() + "/.codex/sessions"
    ) {
        self.monitor = monitor
        self.historyPath = historyPath
        self.sessionsRoot = sessionsRoot
    }

    func start() {
        poll()
    }

    func poll() {
        let now = Date()
        guard now.timeIntervalSince(lastPollAt) >= minimumPollInterval else { return }
        lastPollAt = now

        discoverSessionFiles()
        loadHistory()
        processSessionFiles()
    }

    private func discoverSessionFiles() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: sessionsRoot) else { return }
        let cutoff = Date().addingTimeInterval(-recentWindow)
        var candidates: [(path: String, modifiedAt: Date)] = []

        for case let relative as String in enumerator {
            guard relative.hasSuffix(".jsonl") else { continue }
            let path = (sessionsRoot as NSString).appendingPathComponent(relative)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modifiedAt = attrs[.modificationDate] as? Date,
                  modifiedAt >= cutoff else { continue }
            candidates.append((path, modifiedAt))
        }

        for item in candidates.sorted(by: { $0.modifiedAt > $1.modifiedAt }).prefix(40) {
            registerSessionFile(item.path)
        }
    }

    private func registerSessionFile(_ path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return }

        // 用文件修改时间作为备选时间戳
        let fileModTime: Date? = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let modDate = attrs[.modificationDate] as? Date {
                return modDate
            }
            return nil
        }()

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.prefix(12) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["type"] as? String) == "session_meta",
                  let payload = json["payload"] as? [String: Any],
                  let sessionId = payload["id"] as? String else { continue }

            let cwd = payload["cwd"] as? String ?? ""
            // 使用文件修改时间作为会话活跃时间（更准确反映最近活动）
            // session_meta 时间戳只用于没有文件修改时间的情况
            guard let timestamp = fileModTime ?? parseISO8601(payload["timestamp"] as? String) else {
                // 如果都没有有效时间，跳过（不要用当前时间污染）
                sessionFiles[sessionId] = path
                sessionCwds[sessionId] = cwd
                return
            }
            sessionFiles[sessionId] = path
            sessionCwds[sessionId] = cwd
            monitor.upsertExternalSession(id: sessionId, source: .codex, cwd: cwd, timestamp: timestamp)
            if fileLineOffsets[path] == nil {
                fileLineOffsets[path] = 0
            }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let modifiedAt = attrs[.modificationDate] as? Date {
                fileModifiedAt[path] = modifiedAt
            }
            return
        }
    }

    private func processSessionFiles() {
        for (sessionId, path) in sessionFiles {
            processSessionFile(sessionId: sessionId, path: path)
        }
    }

    private func processSessionFile(sessionId: String, path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modifiedAt = attrs[.modificationDate] as? Date else { return }

        if fileModifiedAt[path] == modifiedAt, (fileLineOffsets[path] ?? 0) > 0 {
            return
        }

        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let startIndex = min(fileLineOffsets[path] ?? 0, lines.count)

        for line in lines[startIndex...] {
            parseSessionLine(sessionId: sessionId, line: String(line))
        }

        fileLineOffsets[path] = lines.count
        fileModifiedAt[path] = modifiedAt
    }

    private func parseSessionLine(sessionId: String, line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        // 必须有有效时间戳才处理，避免使用当前时间污染 lastUpdate
        guard let timestamp = parseISO8601(json["timestamp"] as? String) else { return }
        let cwd = sessionCwds[sessionId] ?? ""

        switch type {
        case "session_meta":
            if let payload = json["payload"] as? [String: Any],
               let sessionCwd = payload["cwd"] as? String {
                sessionCwds[sessionId] = sessionCwd
                monitor.upsertExternalSession(id: sessionId, source: .codex, cwd: sessionCwd, timestamp: timestamp)
            }

        case "response_item":
            parseResponseItem(sessionId: sessionId, payload: json["payload"] as? [String: Any] ?? [:], timestamp: timestamp, cwd: cwd)

        case "event_msg":
            parseEventMessage(sessionId: sessionId, payload: json["payload"] as? [String: Any] ?? [:], timestamp: timestamp, cwd: cwd)

        default:
            break
        }
    }

    private func parseResponseItem(sessionId: String, payload: [String: Any], timestamp: Date, cwd: String) {
        guard let type = payload["type"] as? String else { return }

        switch type {
        case "function_call":
            guard let callId = payload["call_id"] as? String,
                  processedCallIds.insert(callId).inserted,
                  let name = payload["name"] as? String else { return }
            let arguments = parseJSONStringDictionary(payload["arguments"] as? String)

            // update_plan 只更新任务列表，不作为工具调用显示
            if name == "update_plan", let plan = arguments["plan"] as? [[String: String]] {
                monitor.updateExternalTasks(sessionId: sessionId, source: .codex, plan: plan, time: timestamp, cwd: cwd)
                return
            }

            let toolName = mapFunctionToolName(name, arguments: arguments)
            let toolCall = ToolCall(tool: toolName, input: arguments, time: timestamp)
            monitor.addExternalToolCall(sessionId: sessionId, source: .codex, toolCall: toolCall, time: timestamp, cwd: cwd)

        case "custom_tool_call":
            guard let callId = payload["call_id"] as? String,
                  processedCallIds.insert(callId).inserted,
                  let name = payload["name"] as? String else { return }
            let input = mapCustomToolInput(name: name, rawInput: payload["input"])
            let toolCall = ToolCall(tool: mapCustomToolName(name), input: input, time: timestamp)
            monitor.addExternalToolCall(sessionId: sessionId, source: .codex, toolCall: toolCall, time: timestamp, cwd: cwd)

        case "web_search_call":
            // Web 搜索调用
            if let action = payload["action"] as? [String: Any],
               let actionType = action["type"] as? String {
                let key = "\(sessionId)-websearch-\(Int(timestamp.timeIntervalSince1970 * 1000))"
                guard processedCallIds.insert(key).inserted else { return }

                var input: [String: Any] = ["action": actionType]
                if let query = action["query"] as? String {
                    input["query"] = query
                }
                let toolCall = ToolCall(tool: "WebSearch", input: input, time: timestamp)
                monitor.addExternalToolCall(sessionId: sessionId, source: .codex, toolCall: toolCall, time: timestamp, cwd: cwd)
            }

        case "function_call_output", "custom_tool_call_output":
            monitor.markExternalActivity(sessionId: sessionId, source: .codex, time: timestamp, cwd: cwd)

        default:
            break
        }
    }

    private func parseEventMessage(sessionId: String, payload: [String: Any], timestamp: Date, cwd: String) {
        guard let type = payload["type"] as? String else { return }

        switch type {
        case "task_started", "token_count":
            monitor.markExternalActivity(sessionId: sessionId, source: .codex, time: timestamp, cwd: cwd)

        case "patch_apply_end":
            // Patch 应用完成 - 文件编辑
            if let path = payload["path"] as? String {
                let key = "\(sessionId)-patch-\(Int(timestamp.timeIntervalSince1970 * 1000))-\(path.hashValue)"
                guard processedCallIds.insert(key).inserted else { return }
                let toolCall = ToolCall(
                    tool: "Edit",
                    input: ["file_path": path, "patch_applied": true],
                    time: timestamp
                )
                monitor.addExternalToolCall(sessionId: sessionId, source: .codex, toolCall: toolCall, time: timestamp, cwd: cwd)
            }

        case "user_message":
            guard let prompt = payload["message"] as? String else { return }
            let key = "\(sessionId)-\(Int(timestamp.timeIntervalSince1970))-\(prompt.hashValue)"
            guard processedPromptKeys.insert(key).inserted else { return }
            monitor.addExternalPrompt(sessionId: sessionId, source: .codex, prompt: prompt, time: timestamp, cwd: cwd)

        case "task_complete":
            guard let text = payload["last_agent_message"] as? String else { return }
            let key = "\(sessionId)-complete-\(text.hashValue)"
            guard processedSummaryKeys.insert(key).inserted else { return }
            monitor.setExternalSummary(sessionId: sessionId, source: .codex, summaryText: text, time: timestamp, cwd: cwd)

        case "agent_message":
            guard let text = payload["message"] as? String, !text.isEmpty else { return }
            let phase = payload["phase"] as? String ?? ""

            if phase == "final_answer" {
                let key = "\(sessionId)-final-\(text.hashValue)"
                guard processedSummaryKeys.insert(key).inserted else { return }
                monitor.setExternalSummary(sessionId: sessionId, source: .codex, summaryText: text, time: timestamp, cwd: cwd)
            } else {
                let key = "\(sessionId)-message-\(Int(timestamp.timeIntervalSince1970 * 1000))-\(text.hashValue)"
                guard processedMessageKeys.insert(key).inserted else { return }
                let toolCall = ToolCall(
                    tool: "Message",
                    input: ["message": text, "phase": phase],
                    time: timestamp
                )
                monitor.addExternalToolCall(sessionId: sessionId, source: .codex, toolCall: toolCall, time: timestamp, cwd: cwd)
            }

        default:
            break
        }
    }

    private func loadHistory() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: historyPath),
              let modifiedAt = attrs[.modificationDate] as? Date else { return }

        if historyModifiedAt == modifiedAt {
            return
        }

        guard let data = FileManager.default.contents(atPath: historyPath),
              let content = String(data: data, encoding: .utf8) else { return }

        let cutoff = Date().addingTimeInterval(-recentWindow)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines.suffix(300) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = json["session_id"] as? String,
                  let prompt = json["text"] as? String,
                  let ts = (json["ts"] as? NSNumber)?.doubleValue else { continue }

            let time = Date(timeIntervalSince1970: ts)
            guard time >= cutoff else { continue }

            let key = "\(sessionId)-\(Int(ts))-\(prompt.hashValue)"
            guard processedPromptKeys.insert(key).inserted else { continue }

            let cwd = sessionCwds[sessionId] ?? ""
            monitor.addExternalPrompt(sessionId: sessionId, source: .codex, prompt: prompt, time: time, cwd: cwd)
        }

        historyModifiedAt = modifiedAt
    }

    private func mapFunctionToolName(_ name: String, arguments: [String: Any] = [:]) -> String {
        switch name {
        case "exec_command":
            // 从命令内容推断实际操作类型
            return inferToolFromCommand(arguments)
        case "update_plan":
            return "TaskUpdate"
        case "list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource":
            return "Read"
        case "view_image":
            return "Read"
        default:
            return name
        }
    }

    /// 从 exec_command 的命令内容推断实际工具类型
    private func inferToolFromCommand(_ arguments: [String: Any]) -> String {
        // Codex 用 cmd，有时也用 command
        guard let cmd = arguments["cmd"] as? String ?? arguments["command"] as? String else {
            return "Bash"
        }

        let trimmed = cmd.trimmingCharacters(in: .whitespaces)

        // 读取文件：cat, head, tail, sed -n (打印), less, more
        if trimmed.hasPrefix("cat ") ||
           trimmed.hasPrefix("head ") ||
           trimmed.hasPrefix("tail ") ||
           trimmed.hasPrefix("less ") ||
           trimmed.hasPrefix("more ") ||
           trimmed.contains("sed -n ") {
            return "Read"
        }

        // 搜索内容：rg, grep, ag, ack
        if trimmed.hasPrefix("rg ") ||
           trimmed.hasPrefix("grep ") ||
           trimmed.hasPrefix("ag ") ||
           trimmed.hasPrefix("ack ") {
            // rg --files 是列出文件，属于 Glob
            if trimmed.contains("--files") {
                return "Glob"
            }
            return "Grep"
        }

        // 搜索文件：find, fd, ls (带 pattern)
        if trimmed.hasPrefix("find ") ||
           trimmed.hasPrefix("fd ") {
            return "Glob"
        }

        // 写入文件：echo > 或 cat > 或 tee
        if trimmed.contains(" > ") || trimmed.contains(" >> ") ||
           trimmed.hasPrefix("tee ") {
            return "Write"
        }

        // Git 操作
        if trimmed.hasPrefix("git ") {
            return "Git"
        }

        // 默认为 Bash
        return "Bash"
    }

    private func mapCustomToolName(_ name: String) -> String {
        switch name {
        case "apply_patch":
            return "Edit"
        default:
            return name
        }
    }

    private func mapCustomToolInput(name: String, rawInput: Any?) -> [String: Any] {
        switch name {
        case "apply_patch":
            let patch = rawInput as? String ?? ""
            var input: [String: Any] = ["patch": patch]
            if let path = extractPatchedFile(from: patch) {
                input["file_path"] = path
            }
            return input
        default:
            return [:]
        }
    }

    private func extractPatchedFile(from patch: String) -> String? {
        for line in patch.split(separator: "\n") {
            if line.hasPrefix("*** Update File: ") {
                return String(line.replacingOccurrences(of: "*** Update File: ", with: ""))
            }
            if line.hasPrefix("*** Add File: ") {
                return String(line.replacingOccurrences(of: "*** Add File: ", with: ""))
            }
        }
        return nil
    }

    private func parseJSONStringDictionary(_ value: String?) -> [String: Any] {
        guard let value,
              let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
