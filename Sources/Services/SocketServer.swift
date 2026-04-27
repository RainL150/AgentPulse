import Foundation

/// Unix Socket 服务器，用于接收权限请求和问答请求
/// 优化版本：事件驱动监听 + 双写保护，实现零延迟竞速模式
class SocketServer: ObservableObject {
    private let path: String
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let serverQueue = DispatchQueue(label: "socket.server", qos: .userInitiated)
    private let responseQueue = DispatchQueue(label: "socket.response", qos: .userInitiated)

    // 待处理的请求
    @Published var pendingPermissions: [PermissionRequest] = []
    @Published var pendingQuestions: [AskRequest] = []

    private var permissionFds: [String: Int32] = [:]
    private var questionFds: [String: Int32] = [:]

    // 双写保护：已处理的请求ID集合
    private var handledRequests: Set<String> = []
    private let handledQueue = DispatchQueue(label: "socket.handled", qos: .userInitiated)

    // DispatchSource 监听socket事件（事件驱动，零延迟检测）
    private var permissionSources: [String: DispatchSourceRead] = [:]
    private var questionSources: [String: DispatchSourceRead] = [:]

    var onPermissionRequest: ((PermissionRequest) -> Void)?
    var onAskRequest: ((AskRequest) -> Void)?

    init(path: String) {
        self.path = path
    }

    func start() {
        guard !isRunning else { return }
        serverQueue.async { [weak self] in
            self?.runServer()
        }
        NSLog("🚀 SocketServer 启动完成（事件驱动模式）")
    }

    func stop() {
        isRunning = false

        // 取消所有DispatchSource
        for (_, source) in permissionSources {
            source.cancel()
        }
        for (_, source) in questionSources {
            source.cancel()
        }

        // 关闭所有fd
        for (_, fd) in permissionFds {
            close(fd)
        }
        for (_, fd) in questionFds {
            close(fd)
        }

        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(path)
    }

    // MARK: - 清除会话的所有待处理请求

    func clearRequestsForSession(_ sessionId: String) {
        responseQueue.async { [weak self] in
            guard let self = self else { return }

            let permissionIds = self.pendingPermissions
                .filter { $0.sessionId == sessionId }
                .map { $0.id }

            let questionIds = self.pendingQuestions
                .filter { $0.sessionId == sessionId }
                .map { $0.id }

            // 关闭并清理权限请求
            for id in permissionIds {
                if let fd = self.permissionFds[id] {
                    self.permissionSources[id]?.cancel()
                    self.permissionSources.removeValue(forKey: id)
                    close(fd)
                    self.permissionFds.removeValue(forKey: id)
                }
            }

            // 关闭并清理问题请求
            for id in questionIds {
                if let fd = self.questionFds[id] {
                    self.questionSources[id]?.cancel()
                    self.questionSources.removeValue(forKey: id)
                    close(fd)
                    self.questionFds.removeValue(forKey: id)
                }
            }

            if !permissionIds.isEmpty || !questionIds.isEmpty {
                DispatchQueue.main.async {
                    self.pendingPermissions.removeAll { permissionIds.contains($0.id) }
                    self.pendingQuestions.removeAll { questionIds.contains($0.id) }
                    NSLog("🧹 清除会话 %@ 的 %d 个权限请求和 %d 个问题", sessionId, permissionIds.count, questionIds.count)
                }
            }
        }
    }

    // MARK: - 响应权限请求

    func respondPermission(requestId: String, approved: Bool, reason: String? = nil) {
        responseQueue.async { [weak self] in
            guard let self = self else { return }

            // 双写保护：检查是否已处理
            let alreadyHandled = self.handledQueue.sync { () -> Bool in
                if self.handledRequests.contains(requestId) {
                    return true
                }
                self.handledRequests.insert(requestId)
                return false
            }

            if alreadyHandled {
                NSLog("⚠️ 权限请求 %@ 已被处理，跳过重复响应", requestId)
                DispatchQueue.main.async {
                    self.pendingPermissions.removeAll { $0.id == requestId }
                }
                return
            }

            guard let fd = self.permissionFds[requestId] else {
                NSLog("⚠️ 权限请求 %@ 的socket已关闭（可能终端已响应）", requestId)
                DispatchQueue.main.async {
                    self.pendingPermissions.removeAll { $0.id == requestId }
                }
                return
            }

            var response: [String: Any] = [
                "action": approved ? "approve" : "deny",
                "request_id": requestId
            ]
            if let r = reason {
                response["reason"] = r
            }

            if let data = try? JSONSerialization.data(withJSONObject: response),
               let json = String(data: data, encoding: .utf8) {
                _ = json.withCString { ptr in
                    write(fd, ptr, strlen(ptr))
                }
            }

            // 取消监听并关闭
            self.permissionSources[requestId]?.cancel()
            self.permissionSources.removeValue(forKey: requestId)
            close(fd)
            self.permissionFds.removeValue(forKey: requestId)

            DispatchQueue.main.async {
                self.pendingPermissions.removeAll { $0.id == requestId }
                NSLog("✅ 灵动岛响应权限请求: %@ (%@)", requestId, approved ? "批准" : "拒绝")
            }
        }
    }

    // MARK: - 响应问答请求

    func respondQuestion(requestId: String, answer: String) {
        responseQueue.async { [weak self] in
            guard let self = self else { return }

            // 双写保护：检查是否已处理
            let alreadyHandled = self.handledQueue.sync { () -> Bool in
                if self.handledRequests.contains(requestId) {
                    return true
                }
                self.handledRequests.insert(requestId)
                return false
            }

            if alreadyHandled {
                NSLog("⚠️ 问答请求 %@ 已被处理，跳过重复响应", requestId)
                DispatchQueue.main.async {
                    self.pendingQuestions.removeAll { $0.id == requestId }
                }
                return
            }

            guard let fd = self.questionFds[requestId] else {
                NSLog("⚠️ 问答请求 %@ 的socket已关闭（可能终端已响应）", requestId)
                DispatchQueue.main.async {
                    self.pendingQuestions.removeAll { $0.id == requestId }
                }
                return
            }

            let response: [String: Any] = [
                "answer": answer,
                "request_id": requestId
            ]

            if let data = try? JSONSerialization.data(withJSONObject: response),
               let json = String(data: data, encoding: .utf8) {
                _ = json.withCString { ptr in
                    write(fd, ptr, strlen(ptr))
                }
            }

            // 取消监听并关闭
            self.questionSources[requestId]?.cancel()
            self.questionSources.removeValue(forKey: requestId)
            close(fd)
            self.questionFds.removeValue(forKey: requestId)

            DispatchQueue.main.async {
                self.pendingQuestions.removeAll { $0.id == requestId }
                NSLog("✅ 灵动岛响应问答请求: %@ = %@", requestId, answer)
            }
        }
    }

    // MARK: - 事件驱动Socket监听（核心优化）

    /// 为fd创建DispatchSource，监听socket事件，实现零延迟检测
    private func setupEventSource(fd: Int32, requestId: String, isPermission: Bool) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: responseQueue)

        source.setEventHandler { [weak self] in
            guard let self = self else { return }

            // 检测socket状态
            var buf: CChar = 0
            let n = recv(fd, &buf, 1, MSG_PEEK | MSG_DONTWAIT)

            if n == 0 {
                // EOF - socket已关闭（终端已响应）
                NSLog("🔔 检测到终端响应: %@ (socket EOF)", requestId)
                self.handleTerminalResponse(requestId: requestId, isPermission: isPermission)
            } else if n < 0 && (errno == ECONNRESET || errno == EPIPE) {
                // 连接重置
                NSLog("🔔 检测到终端响应: %@ (socket reset)", requestId)
                self.handleTerminalResponse(requestId: requestId, isPermission: isPermission)
            }
        }

        source.setCancelHandler {
            // source被取消时的清理
        }

        source.resume()

        // 保存source引用
        if isPermission {
            permissionSources[requestId] = source
        } else {
            questionSources[requestId] = source
        }

        NSLog("📡 启动事件监听: %@ (fd=%d)", requestId, fd)
    }

    /// 处理终端响应（socket关闭事件）
    private func handleTerminalResponse(requestId: String, isPermission: Bool) {
        // 双写保护：标记为已处理
        handledQueue.sync {
            _ = handledRequests.insert(requestId)
        }

        if isPermission {
            if let source = permissionSources[requestId] {
                source.cancel()
                permissionSources.removeValue(forKey: requestId)
            }
            if let fd = permissionFds[requestId] {
                close(fd)
                permissionFds.removeValue(forKey: requestId)
            }

            DispatchQueue.main.async { [weak self] in
                self?.pendingPermissions.removeAll { $0.id == requestId }
                NSLog("✅ 终端响应权限请求: %@", requestId)
            }
        } else {
            if let source = questionSources[requestId] {
                source.cancel()
                questionSources.removeValue(forKey: requestId)
            }
            if let fd = questionFds[requestId] {
                close(fd)
                questionFds.removeValue(forKey: requestId)
            }

            DispatchQueue.main.async { [weak self] in
                self?.pendingQuestions.removeAll { $0.id == requestId }
                NSLog("✅ 终端响应问答请求: %@", requestId)
            }
        }
    }

    // MARK: - Server Loop

    private func runServer() {
        unlink(path)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            print("Failed to create socket")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            print("Failed to bind socket: \(errno)")
            return
        }

        guard listen(serverSocket, 5) == 0 else {
            print("Failed to listen")
            return
        }

        print("Socket server listening on \(path)")
        isRunning = true

        while isRunning {
            var clientAddr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverSocket, sockaddrPtr, &addrLen)
                }
            }

            guard clientFd >= 0 else { continue }
            handleClient(fd: clientFd)
        }
    }

    private func handleClient(fd: Int32) {
        var buffer = [CChar](repeating: 0, count: 8192)
        let bytesRead = read(fd, &buffer, buffer.count - 1)

        guard bytesRead > 0,
              let jsonStr = String(cString: buffer, encoding: .utf8),
              let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            close(fd)
            return
        }

        let requestType = json["type"] as? String ?? ""

        switch requestType {
        case "permission":
            let sessionId = json["session_id"] as? String ?? ""
            let tool = json["tool"] as? String ?? ""
            let inputData = json["input"] as? [String: Any] ?? [:]

            // AskUserQuestion 应该作为提问处理
            if tool == "AskUserQuestion" {
                let questions = inputData["questions"] as? [[String: Any]] ?? []
                let request = AskRequest(
                    id: UUID().uuidString,
                    sessionId: sessionId,
                    questions: questions,
                    timestamp: Date()
                )
                questionFds[request.id] = fd
                setupEventSource(fd: fd, requestId: request.id, isPermission: false)

                DispatchQueue.main.async { [weak self] in
                    self?.pendingQuestions.append(request)
                    self?.onAskRequest?(request)
                }
                return
            }

            // 去重
            let inputHash = (try? JSONSerialization.data(withJSONObject: inputData))?.hashValue ?? 0
            let dedupeKey = "\(sessionId)-\(tool)-\(inputHash)"

            let request = PermissionRequest(
                id: dedupeKey,
                sessionId: sessionId,
                tool: tool,
                input: inputData,
                timestamp: Date()
            )

            if permissionFds[request.id] != nil {
                close(fd)
                return
            }

            permissionFds[request.id] = fd
            setupEventSource(fd: fd, requestId: request.id, isPermission: true)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !self.pendingPermissions.contains(where: { $0.id == request.id }) {
                    self.pendingPermissions.append(request)
                    self.onPermissionRequest?(request)
                }
            }

        case "ask":
            let questions = json["questions"] as? [[String: Any]] ?? []
            let request = AskRequest(
                id: UUID().uuidString,
                sessionId: json["session_id"] as? String ?? "",
                questions: questions,
                timestamp: Date()
            )

            questionFds[request.id] = fd
            setupEventSource(fd: fd, requestId: request.id, isPermission: false)

            DispatchQueue.main.async { [weak self] in
                self?.pendingQuestions.append(request)
                self?.onAskRequest?(request)
            }

        default:
            close(fd)
        }
    }
}
