import Foundation
import Combine

class SessionMonitor: ObservableObject {
    static let shared = SessionMonitor()

    @Published var sessions: [Session] = []
    @Published var activeCount: Int = 0

    private var sessionMap: [String: Session] = [:]

    private init() {}

    func handleRecord(_ record: LogRecord) {
        let session = getOrCreateSession(id: record.sessionId)
        session.source = .claude
        session.lastUpdate = record.timestamp
        session.cwd = record.cwd ?? session.cwd

        switch record.type {
        case "prompt":
            // 新的用户请求
            if let prompt = record.prompt {
                let request = UserRequest(prompt: prompt, time: record.timestamp)
                session.requests.append(request)
                session.isActive = true
            }

        case "tool":
            // 工具调用
            if record.event == "PostToolUse",
               let tool = record.tool {
                let toolCall = ToolCall(
                    tool: tool,
                    input: record.input ?? [:],
                    time: record.timestamp
                )
                session.currentRequest?.tools.append(toolCall)

                // 处理任务创建/更新
                if tool == "TaskCreate", let input = record.input {
                    handleTaskCreate(session: session, input: input)
                } else if tool == "TaskUpdate", let input = record.input {
                    handleTaskUpdate(session: session, input: input)
                }
            }

        case "summary":
            // AI 生成的总结
            if let summaryText = record.summary,
               let summary = Summary(raw: summaryText) {
                // 匹配到对应的请求
                if let promptPrefix = record.prompt?.prefix(100) {
                    for request in session.requests.reversed() {
                        if request.prompt.hasPrefix(String(promptPrefix)) {
                            request.summary = summary
                            break
                        }
                    }
                } else {
                    session.currentRequest?.summary = summary
                }
            }

        case "stop":
            // 会话暂停
            session.isActive = false

        default:
            break
        }

        updateActiveCount()
        objectWillChange.send()
    }

    func upsertExternalSession(id: String, source: SessionAgent, cwd: String, timestamp: Date) {
        let session = getOrCreateSession(id: id)
        session.source = source
        session.lastUpdate = max(session.lastUpdate, timestamp)
        if !cwd.isEmpty {
            session.cwd = cwd
        }
        session.isActive = isRecentExternalActivity(session.lastUpdate)
        updateActiveCount()
        objectWillChange.send()
    }

    func addExternalPrompt(sessionId: String, source: SessionAgent, prompt: String, time: Date, cwd: String) {
        let session = getOrCreateSession(id: sessionId)
        session.source = source
        session.lastUpdate = max(session.lastUpdate, time)
        if !cwd.isEmpty {
            session.cwd = cwd
        }
        if session.currentRequest?.prompt != prompt {
            let request = UserRequest(prompt: prompt, time: time)
            session.requests.append(request)
        }
        session.isActive = isRecentExternalActivity(session.lastUpdate)
        updateActiveCount()
        objectWillChange.send()
    }

    func addExternalToolCall(sessionId: String, source: SessionAgent, toolCall: ToolCall, time: Date, cwd: String) {
        let session = getOrCreateSession(id: sessionId)
        session.source = source
        session.lastUpdate = max(session.lastUpdate, time)
        if !cwd.isEmpty {
            session.cwd = cwd
        }
        if session.requests.isEmpty {
            session.requests.append(UserRequest(prompt: source == .codex ? "Codex 会话" : "外部会话", time: time))
        }
        session.requests[session.requests.count - 1].tools.append(toolCall)
        session.isActive = isRecentExternalActivity(session.lastUpdate)
        updateActiveCount()
        objectWillChange.send()
    }

    func updateExternalTasks(sessionId: String, source: SessionAgent, plan: [[String: String]], time: Date, cwd: String) {
        let session = getOrCreateSession(id: sessionId)
        session.source = source
        session.lastUpdate = max(session.lastUpdate, time)
        if !cwd.isEmpty {
            session.cwd = cwd
        }
        session.tasks = plan.enumerated().map { idx, item in
            Task(
                id: String(idx + 1),
                subject: item["step"] ?? "未命名任务",
                status: taskStatus(from: item["status"] ?? ""),
                activeForm: nil
            )
        }
        session.isActive = isRecentExternalActivity(session.lastUpdate)
        updateActiveCount()
        objectWillChange.send()
    }

    func setExternalSummary(sessionId: String, source: SessionAgent, summaryText: String, time: Date, cwd: String) {
        let session = getOrCreateSession(id: sessionId)
        session.source = source
        session.lastUpdate = max(session.lastUpdate, time)
        if !cwd.isEmpty {
            session.cwd = cwd
        }
        if session.requests.isEmpty {
            session.requests.append(UserRequest(prompt: source == .codex ? "Codex 会话" : "外部会话", time: time))
        }
        session.requests[session.requests.count - 1].summary = Summary(raw: summaryText)
        session.isActive = isRecentExternalActivity(session.lastUpdate)
        updateActiveCount()
        objectWillChange.send()
    }

    private func isRecentExternalActivity(_ date: Date) -> Bool {
        Date().timeIntervalSince(date) < 45 * 60
    }

    private func taskStatus(from value: String) -> TaskStatus {
        switch value {
        case "completed":
            return .completed
        case "in_progress", "inProgress":
            return .inProgress
        default:
            return .pending
        }
    }

    private func getOrCreateSession(id: String) -> Session {
        if let existing = sessionMap[id] {
            return existing
        }
        let session = Session(id: id)
        sessionMap[id] = session
        sessions.insert(session, at: 0)
        return session
    }

    private func handleTaskCreate(session: Session, input: [String: Any]) {
        guard let subject = input["subject"] as? String else { return }
        let taskId = String(session.tasks.count + 1)
        let task = Task(
            id: taskId,
            subject: subject,
            status: .pending,
            activeForm: input["activeForm"] as? String
        )
        session.tasks.append(task)
    }

    private func handleTaskUpdate(session: Session, input: [String: Any]) {
        guard let taskId = input["taskId"] as? String,
              let statusStr = input["status"] as? String,
              let status = TaskStatus(rawValue: statusStr) else { return }

        if let idx = session.tasks.firstIndex(where: { $0.id == taskId }) {
            session.tasks[idx].status = status
            if let subject = input["subject"] as? String {
                session.tasks[idx].subject = subject
            }
        }
    }

    private func updateActiveCount() {
        activeCount = sessions.filter { $0.isActive }.count
    }

    // 清理旧会话
    func cleanup(olderThan hours: Int = 24) {
        let cutoff = Date().addingTimeInterval(-Double(hours * 3600))
        sessions.removeAll { $0.lastUpdate < cutoff }
        sessionMap = sessionMap.filter { $0.value.lastUpdate >= cutoff }
    }
}
