import Foundation
import Combine

class SessionMonitor: ObservableObject {
    static let shared = SessionMonitor()

    @Published var sessions: [Session] = []
    @Published var activeCount: Int = 0

    private var sessionMap: [String: Session] = [:]

    /// 会话变为 idle 的超时时间（秒）
    private let idleTimeout: TimeInterval = 300 // 5分钟无活动变为 idle
    /// Codex 的本地 session JSONL 写入更稀疏，状态保活窗口需要更长。
    private let codexIdleTimeout: TimeInterval = 1800 // 30分钟无活动变为 idle
    /// 会话变为 expired 的超时时间（秒）
    private let expiredTimeout: TimeInterval = 7200 // 2小时后过期
    /// Codex 会话的过期时间更长（与 CodexWatcher.recentWindow 一致）
    private let codexExpiredTimeout: TimeInterval = 43200 // 12小时后过期

    /// 会话被中断时的回调（用于清除待处理的权限/问题请求）
    var onSessionStopped: ((String) -> Void)?

    /// 会话完成时的回调（收到 summary）
    var onSessionCompleted: ((Session, String) -> Void)?

    /// 会话被中断时的通知回调
    var onSessionInterrupted: ((Session, String) -> Void)?

    /// 检查会话是否有待处理的权限/问题请求（用于区分中断和等待审批）
    var hasPendingRequestForSession: ((String) -> Bool)?

    /// 已通知的完成记录（用于去重）
    private var notifiedCompletions: [String: Date] = [:]  // key: sessionId+summaryHash
    private let notificationDedupeWindow: TimeInterval = 60  // 60秒内相同通知只发一次

    /// 应用启动时间（用于过滤旧记录的通知）
    private let appLaunchTime = Date()
    /// 启动后多少秒内的旧记录不触发通知（给启动留缓冲）
    private let launchGracePeriod: TimeInterval = 5

    /// 待检查的中断通知（延迟发送，等待可能的 summary）
    private var pendingInterruptionChecks: [String: DispatchWorkItem] = [:]

    /// 等待 summary 的超时时间（generate-summary.js 最多需要 15 秒）
    private let summaryWaitTimeout: TimeInterval = 18

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
                request.events.append(WorkflowEvent(
                    type: .userMessage,
                    title: "用户请求",
                    detail: prompt,
                    time: record.timestamp,
                    status: .success
                ))
                session.requests.append(request)
                session.state = .running
                // 清空旧任务计划，新请求从头开始
                session.tasks.removeAll()
                taskIdMapping[session.id] = nil
            }

        case "tool":
            // 工具调用
            if record.event == "PostToolUse",
               let tool = record.tool {
                // 有工具调用说明正在运行
                session.state = .running

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
                appendEvent(
                    WorkflowEvent(
                        type: .toolCall,
                        title: tool,
                        detail: toolCall.fullDetail,
                        time: record.timestamp,
                        status: toolCall.status.workflowStatus,
                        toolName: tool
                    ),
                    to: session,
                    fallbackPrompt: "Claude 会话",
                    time: record.timestamp
                )

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
                // 有 summary 说明任务正常完成
                session.state = .completed

                var summaryChanged = false

                // 匹配到对应的请求
                if let promptPrefix = record.prompt?.prefix(100) {
                    for request in session.requests.reversed() {
                        if request.prompt.hasPrefix(String(promptPrefix)) {
                            if request.summary?.result != summary.result || request.summary?.flow != summary.flow {
                                request.summary = summary
                                request.events.append(summaryEvent(summary: summary, time: record.timestamp))
                                summaryChanged = true
                            }
                            break
                        }
                    }
                } else {
                    if session.currentRequest?.summary?.result != summary.result ||
                        session.currentRequest?.summary?.flow != summary.flow {
                        session.currentRequest?.summary = summary
                        appendEvent(
                            summaryEvent(summary: summary, time: record.timestamp),
                            to: session,
                            fallbackPrompt: "Claude 会话",
                            time: record.timestamp
                        )
                        summaryChanged = true
                    }
                }

                guard summaryChanged else { break }
                // 跳过启动期间加载的旧记录（不触发通知）
                let timeSinceLaunch = Date().timeIntervalSince(appLaunchTime)
                let timeSinceRecord = Date().timeIntervalSince(record.timestamp)
                if timeSinceLaunch < launchGracePeriod && timeSinceRecord > launchGracePeriod {
                    // 启动后5秒内，如果记录本身也是5秒前的，跳过通知
                    break
                }
                // 通知会话完成（带去重）
                let completionKey = "\(record.sessionId)-\(summary.result.hashValue)"
                let now = Date()
                cleanupOldNotifications(before: now.addingTimeInterval(-notificationDedupeWindow))
                if notifiedCompletions[completionKey] == nil {
                    notifiedCompletions[completionKey] = now
                    onSessionCompleted?(session, summary.result)
                }
            }

        case "stop":
            // 会话停止 - Claude Code 不传递 stop_reason，默认为完成
            let hasPendingRequest = hasPendingRequestForSession?(record.sessionId) ?? false

            if hasPendingRequest {
                // 有待处理的权限/问题请求
                session.state = .waiting
            } else {
                // 默认为正常完成
                session.state = .completed
            }

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
        // 始终使用较新的时间戳（文件修改时间反映最近活动）
        session.lastUpdate = max(session.lastUpdate, timestamp)
        if !cwd.isEmpty {
            session.cwd = cwd
        }
        // 已有 summary 的会话保持完成态，避免历史文件扫描把它重新拉回 running。
        if session.currentRequest?.summary == nil {
            session.state = stateForExternalActivity(session.lastUpdate, source: source)
        }
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
            request.events.append(WorkflowEvent(
                type: .userMessage,
                title: "用户请求",
                detail: prompt,
                time: time,
                status: .success
            ))
            session.requests.append(request)
        }
        session.state = .running  // 有新 prompt 说明正在运行
        updateActiveCount()
        objectWillChange.send()
    }

    func markExternalActivity(sessionId: String, source: SessionAgent, time: Date, cwd: String) {
        let session = getOrCreateSession(id: sessionId)
        session.source = source
        session.lastUpdate = max(session.lastUpdate, time)
        if !cwd.isEmpty {
            session.cwd = cwd
        }
        if session.currentRequest?.summary == nil && session.state != .stopped {
            session.state = .running
        }
        updateActiveCount()
        objectWillChange.send()
    }

    func addPermissionWorkflowEvent(_ permission: PermissionRequest) {
        let session = getOrCreateSession(id: permission.sessionId)
        session.lastUpdate = max(session.lastUpdate, permission.timestamp)
        appendEvent(
            WorkflowEvent(
                type: .permissionRequest,
                title: "权限申请",
                detail: "\(permission.tool): \(permission.summary)",
                time: permission.timestamp,
                status: .waiting,
                toolName: permission.tool
            ),
            to: session,
            fallbackPrompt: session.source == .codex ? "Codex 会话" : "Claude 会话",
            time: permission.timestamp
        )
        session.state = .waiting
        updateActiveCount()
        objectWillChange.send()
    }

    func addQuestionWorkflowEvent(_ question: AskRequest) {
        let session = getOrCreateSession(id: question.sessionId)
        session.lastUpdate = max(session.lastUpdate, question.timestamp)
        appendEvent(
            WorkflowEvent(
                type: .question,
                title: "需要回答",
                detail: question.firstQuestion,
                time: question.timestamp,
                status: .waiting,
                toolName: "AskUserQuestion"
            ),
            to: session,
            fallbackPrompt: session.source == .codex ? "Codex 会话" : "Claude 会话",
            time: question.timestamp
        )
        session.state = .waiting
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
        appendEvent(
            workflowEvent(from: toolCall),
            to: session,
            fallbackPrompt: source == .codex ? "Codex 会话" : "外部会话",
            time: time
        )
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
        appendEvent(
            planUpdateEvent(tasks: session.tasks, time: time),
            to: session,
            fallbackPrompt: source == .codex ? "Codex 会话" : "外部会话",
            time: time
        )
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
        let summary = Summary(raw: summaryText)
        session.requests[session.requests.count - 1].summary = summary
        if let summary {
            appendEvent(
                summaryEvent(summary: summary, time: time),
                to: session,
                fallbackPrompt: source == .codex ? "Codex 会话" : "外部会话",
                time: time
            )
        }
        // 有 summary 说明已完成
        session.state = .completed
        updateActiveCount()
        objectWillChange.send()
    }

    /// 根据时间判断外部会话的状态
    private func stateForExternalActivity(_ date: Date, source: SessionAgent) -> SessionState {
        let elapsed = Date().timeIntervalSince(date)
        let idle = idleTimeout(for: source)
        let expired = expiredTimeout(for: source)
        if elapsed < idle {
            return .running
        } else if elapsed < expired {
            return .idle
        } else {
            return .expired
        }
    }

    private func idleTimeout(for source: SessionAgent) -> TimeInterval {
        source == .codex ? codexIdleTimeout : idleTimeout
    }

    private func expiredTimeout(for source: SessionAgent) -> TimeInterval {
        source == .codex ? codexExpiredTimeout : expiredTimeout
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

    private func appendEvent(_ event: WorkflowEvent, to session: Session, fallbackPrompt: String, time: Date) {
        if session.requests.isEmpty {
            session.requests.append(UserRequest(prompt: fallbackPrompt, time: time))
        }
        session.requests[session.requests.count - 1].events.append(event)
    }

    private func workflowEvent(from toolCall: ToolCall) -> WorkflowEvent {
        let type: WorkflowEventType = toolCall.tool == "Message" ? .assistantMessage : .toolCall
        let title = toolCall.tool == "Message" ? "过程说明" : toolCall.tool
        let detail = toolCall.fullDetail.isEmpty ? toolCall.detail : toolCall.fullDetail
        return WorkflowEvent(
            type: type,
            title: title,
            detail: detail,
            time: toolCall.time,
            status: toolCall.status.workflowStatus,
            toolName: toolCall.tool
        )
    }

    private func planUpdateEvent(tasks: [Task], time: Date) -> WorkflowEvent {
        let completed = tasks.filter { $0.status == .completed }.count
        let active = tasks.first { $0.status == .inProgress }
        let detail = active?.activeForm ?? active?.subject ?? "\(completed)/\(tasks.count) 完成"
        return WorkflowEvent(
            type: .planUpdate,
            title: "计划更新",
            detail: detail,
            time: time,
            status: completed == tasks.count && !tasks.isEmpty ? .completed : .running,
            toolName: "TaskUpdate"
        )
    }

    private func summaryEvent(summary: Summary, time: Date) -> WorkflowEvent {
        WorkflowEvent(
            type: .summary,
            title: "完成总结",
            detail: summary.result,
            time: time,
            status: .completed,
            toolName: "Summary"
        )
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

    // 存储 Claude task ID 到内部索引的映射
    private var taskIdMapping: [String: [String: Int]] = [:] // sessionId -> [claudeTaskId -> index]

    private func handleTaskCreate(session: Session, input: [String: Any]) {
        guard let subject = input["subject"] as? String else { return }
        let internalIndex = session.tasks.count
        let taskId = String(internalIndex + 1)
        let task = Task(
            id: taskId,
            subject: subject,
            status: .pending,
            activeForm: input["activeForm"] as? String
        )
        session.tasks.append(task)
        appendEvent(
            planUpdateEvent(tasks: session.tasks, time: session.lastUpdate),
            to: session,
            fallbackPrompt: "Claude 会话",
            time: session.lastUpdate
        )
    }

    private func handleTaskUpdate(session: Session, input: [String: Any]) {
        guard let taskIdStr = input["taskId"] as? String,
              let statusStr = input["status"] as? String,
              let status = TaskStatus(rawValue: statusStr) else { return }

        // 策略1: 直接匹配内部 ID
        if let idx = session.tasks.firstIndex(where: { $0.id == taskIdStr }) {
            session.tasks[idx].status = status
            if let subject = input["subject"] as? String {
                session.tasks[idx].subject = subject
            }
            appendEvent(
                planUpdateEvent(tasks: session.tasks, time: session.lastUpdate),
                to: session,
                fallbackPrompt: "Claude 会话",
                time: session.lastUpdate
            )
            return
        }

        // 策略2: Claude task ID 是全局递增的，计算相对偏移
        // 如果有映射记录，使用映射
        if let mapping = taskIdMapping[session.id],
           let idx = mapping[taskIdStr],
           idx < session.tasks.count {
            session.tasks[idx].status = status
            if let subject = input["subject"] as? String {
                session.tasks[idx].subject = subject
            }
            appendEvent(
                planUpdateEvent(tasks: session.tasks, time: session.lastUpdate),
                to: session,
                fallbackPrompt: "Claude 会话",
                time: session.lastUpdate
            )
            return
        }

        // 策略3: 按顺序更新 - 记录这个 Claude ID 对应的下一个未映射任务
        if taskIdMapping[session.id] == nil {
            taskIdMapping[session.id] = [:]
        }

        // 找到第一个还没有被映射的任务（按状态判断：pending 且未被更新过）
        var mappedIndices = Set<Int>()
        if let mapping = taskIdMapping[session.id] {
            mappedIndices = Set(mapping.values)
        }
        for idx in session.tasks.indices {
            if !mappedIndices.contains(idx) {
                // 建立映射并更新
                taskIdMapping[session.id]?[taskIdStr] = idx
                session.tasks[idx].status = status
                if let subject = input["subject"] as? String {
                    session.tasks[idx].subject = subject
                }
                appendEvent(
                    planUpdateEvent(tasks: session.tasks, time: session.lastUpdate),
                    to: session,
                    fallbackPrompt: "Claude 会话",
                    time: session.lastUpdate
                )
                return
            }
        }
    }

    private func updateActiveCount() {
        activeCount = sessions.filter { $0.state == .running }.count
    }

    /// 清理过期的通知去重记录
    private func cleanupOldNotifications(before cutoff: Date) {
        notifiedCompletions = notifiedCompletions.filter { $0.value > cutoff }
    }

    /// 刷新所有会话的状态（基于最后更新时间）
    func refreshActiveStates() {
        let now = Date()
        var changed = false

        for session in sessions {
            let timeSinceUpdate = now.timeIntervalSince(session.lastUpdate)
            let expired = expiredTimeout(for: session.source)

            // completed/stopped/waiting 状态只检查是否过期，不恢复为 running/idle
            if session.state == .completed || session.state == .stopped || session.state == .waiting {
                if timeSinceUpdate >= expired {
                    session.state = .expired
                    changed = true
                }
                continue
            }

            let newState: SessionState
            if timeSinceUpdate < idleTimeout(for: session.source) {
                newState = .running
            } else if timeSinceUpdate < expired {
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
