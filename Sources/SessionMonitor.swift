import Foundation
import Combine

class SessionMonitor: ObservableObject {
    static let shared = SessionMonitor()

    @Published var sessions: [Session] = []
    @Published var activeCount: Int = 0

    private var sessionMap: [String: Session] = [:]

    /// 会话变为 idle 的超时时间（秒）
    private let idleTimeout: TimeInterval = 300 // 5分钟无活动变为 idle
    /// 会话变为 expired 的超时时间（秒）
    private let expiredTimeout: TimeInterval = 7200 // 2小时后过期

    /// 会话被中断时的回调（用于清除待处理的权限/问题请求）
    var onSessionStopped: ((String) -> Void)?

    /// 会话完成时的回调（收到 summary）
    var onSessionCompleted: ((Session, String) -> Void)?

    private init() {}

    // MARK: - Persistence

    func restoreFromPersistence() {
        let restored = SessionPersistence.shared.load()
        for session in restored {
            sessionMap[session.id] = session
            sessions.append(session)
        }
        // 刷新状态（根据时间判断是否过期）
        refreshActiveStates()
        updateActiveCount()
        objectWillChange.send()
    }

    func saveToPersistence() {
        SessionPersistence.shared.save(sessions: sessions)
    }

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
                session.state = .running
            }

        case "tool":
            // 工具调用
            if record.event == "PostToolUse",
               let tool = record.tool {
                // 计算上一个工具的耗时
                if let currentRequest = session.currentRequest,
                   !currentRequest.tools.isEmpty {
                    let lastIndex = currentRequest.tools.count - 1
                    let lastTool = currentRequest.tools[lastIndex]
                    let duration = record.timestamp.timeIntervalSince(lastTool.time)
                    session.currentRequest?.tools[lastIndex].duration = duration
                }

                var toolCall = ToolCall(
                    tool: tool,
                    input: record.input ?? [:],
                    time: record.timestamp
                )

                // 检测失败状态（通过 error 字段）
                if let error = record.input?["error"] as? String, !error.isEmpty {
                    toolCall.status = .failed
                }

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
                // 通知会话完成
                onSessionCompleted?(session, summary.result)
            }

        case "stop":
            // 会话主动中断
            session.state = .stopped
            // 通知清除该会话的待处理请求
            onSessionStopped?(record.sessionId)

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
        session.state = stateForExternalActivity(session.lastUpdate)
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
        session.state = .running  // 有新 prompt 说明正在运行
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
        session.state = .running  // 有工具调用说明正在运行
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
        session.state = .running  // 有任务更新说明正在运行
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
        session.state = stateForExternalActivity(session.lastUpdate)
        updateActiveCount()
        objectWillChange.send()
    }

    /// 根据时间判断外部会话的状态
    private func stateForExternalActivity(_ date: Date) -> SessionState {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < idleTimeout {
            return .running
        } else if elapsed < expiredTimeout {
            return .idle
        } else {
            return .expired
        }
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
        activeCount = sessions.filter { $0.state == .running }.count
    }

    /// 刷新所有会话的状态（基于最后更新时间）
    func refreshActiveStates() {
        let now = Date()
        var changed = false

        for session in sessions {
            // 已经是 stopped 的会话不自动改变状态（用户主动中断）
            if session.state == .stopped {
                continue
            }

            let timeSinceUpdate = now.timeIntervalSince(session.lastUpdate)
            let newState: SessionState
            if timeSinceUpdate < idleTimeout {
                newState = .running
            } else if timeSinceUpdate < expiredTimeout {
                newState = .idle
            } else {
                newState = .expired
            }

            if session.state != newState {
                session.state = newState
                changed = true
            }
        }

        if changed {
            updateActiveCount()
            objectWillChange.send()
        }
    }

    /// 自动清理：移除过期的会话
    func autoCleanup() {
        let initialCount = sessions.count

        // 移除 expired 状态的会话
        sessions.removeAll { $0.state == .expired }

        // 同步 sessionMap
        let remainingIds = Set(sessions.map { $0.id })
        sessionMap = sessionMap.filter { remainingIds.contains($0.key) }

        if sessions.count != initialCount {
            updateActiveCount()
            objectWillChange.send()
        }
    }

    /// 手动移除指定会话
    func removeSession(id: String) {
        sessions.removeAll { $0.id == id }
        sessionMap.removeValue(forKey: id)
        updateActiveCount()
        objectWillChange.send()
    }

    /// 清理所有非运行中的会话
    func clearInactiveSessions() {
        sessions.removeAll { $0.state != .running }
        let remainingIds = Set(sessions.map { $0.id })
        sessionMap = sessionMap.filter { remainingIds.contains($0.key) }
        updateActiveCount()
        objectWillChange.send()
    }

    // 清理旧会话（保留兼容性）
    func cleanup(olderThan hours: Int = 24) {
        let cutoff = Date().addingTimeInterval(-Double(hours * 3600))
        sessions.removeAll { $0.lastUpdate < cutoff }
        sessionMap = sessionMap.filter { $0.value.lastUpdate >= cutoff }
        updateActiveCount()
        objectWillChange.send()
    }
}
