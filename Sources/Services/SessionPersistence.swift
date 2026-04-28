import Foundation

// MARK: - Persistable Models

struct PersistentSession: Codable {
    let id: String
    let source: String
    let state: String
    let cwd: String
    let lastUpdate: Date
    let requests: [PersistentRequest]
}

struct PersistentRequest: Codable {
    let prompt: String
    let time: Date
    let tools: [PersistentToolCall]
    let summaryFlow: String?
    let summaryResult: String?
}

struct PersistentToolCall: Codable {
    let tool: String
    let input: String  // JSON string
    let time: Date
}

// MARK: - SessionPersistence

class SessionPersistence {
    static let shared = SessionPersistence()

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("AgentPulse")

        // 创建目录
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        fileURL = appDir.appendingPathComponent("sessions.json")

        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Save

    func save(sessions: [Session]) {
        let persistentSessions = sessions.compactMap { convertToPersistent($0) }

        do {
            let data = try encoder.encode(persistentSessions)
            try data.write(to: fileURL, options: .atomic)
            NSLog("SessionPersistence: 保存 \(persistentSessions.count) 个会话")
        } catch {
            NSLog("SessionPersistence: 保存失败 - \(error)")
        }
    }

    // MARK: - Load

    func load() -> [Session] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            NSLog("SessionPersistence: 无持久化文件")
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let persistentSessions = try decoder.decode([PersistentSession].self, from: data)
            let sessions = persistentSessions.compactMap { convertToSession($0) }
            NSLog("SessionPersistence: 恢复 \(sessions.count) 个会话")
            return sessions
        } catch {
            NSLog("SessionPersistence: 加载失败 - \(error)")
            return []
        }
    }

    // MARK: - Convert To Persistent

    private func convertToPersistent(_ session: Session) -> PersistentSession? {
        // 只保存最近24小时的会话
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        guard session.lastUpdate > cutoff else { return nil }

        let requests = session.requests.suffix(10).map { req -> PersistentRequest in
            let tools = req.tools.suffix(50).map { tool -> PersistentToolCall in
                let inputJSON = (try? JSONSerialization.data(withJSONObject: tool.input))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return PersistentToolCall(
                    tool: tool.tool,
                    input: inputJSON,
                    time: tool.time
                )
            }
            return PersistentRequest(
                prompt: req.prompt,
                time: req.time,
                tools: Array(tools),
                summaryFlow: req.summary?.flow,
                summaryResult: req.summary?.result
            )
        }

        return PersistentSession(
            id: session.id,
            source: session.source.rawValue,
            state: session.state.rawValue,
            cwd: session.cwd,
            lastUpdate: session.lastUpdate,
            requests: Array(requests)
        )
    }

    // MARK: - Convert To Session

    private func convertToSession(_ persistent: PersistentSession) -> Session? {
        // 跳过已过期的会话
        let expiredCutoff = Date().addingTimeInterval(-2 * 3600)
        guard persistent.lastUpdate > expiredCutoff else { return nil }

        let session = Session(id: persistent.id)
        session.source = SessionAgent(rawValue: persistent.source) ?? .unknown
        session.state = SessionState(rawValue: persistent.state) ?? .idle
        session.cwd = persistent.cwd
        session.lastUpdate = persistent.lastUpdate

        for req in persistent.requests {
            let userRequest = UserRequest(prompt: req.prompt, time: req.time)

            for tool in req.tools {
                let input: [String: Any]
                if let data = tool.input.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    input = json
                } else {
                    input = [:]
                }
                let toolCall = ToolCall(tool: tool.tool, input: input, time: tool.time)
                userRequest.tools.append(toolCall)
            }

            if let flow = req.summaryFlow, let result = req.summaryResult {
                userRequest.summary = Summary(raw: "流程: \(flow)\n结果: \(result)")
            } else if let result = req.summaryResult {
                userRequest.summary = Summary(raw: result)
            }

            session.requests.append(userRequest)
        }

        return session
    }

    // MARK: - Clear

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        NSLog("SessionPersistence: 已清除持久化数据")
    }
}
