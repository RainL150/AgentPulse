import Foundation

/// Unix Socket 服务器，用于接收权限请求和问答请求
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

    var onPermissionRequest: ((PermissionRequest) -> Void)?
    var onAskRequest: ((AskRequest) -> Void)?

    init(path: String) {
        self.path = path
    }

    func start() {
        guard !isRunning else { return } // 防止重复启动
        serverQueue.async { [weak self] in
            self?.runServer()
        }
        // 定期清理已关闭的连接
        startCleanupTimer()
    }

    private func startCleanupTimer() {
        DispatchQueue.main.async {
            // 每 0.5 秒检查一次，更及时地检测终端中的选择
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.cleanupStaleRequests()
            }
        }
    }

    private func cleanupStaleRequests() {
        responseQueue.async { [weak self] in
            guard let self = self else { return }

            var stalePermissionIds: [String] = []
            var staleQuestionIds: [String] = []

            // 检查权限请求的 socket 是否还有效
            for (id, fd) in self.permissionFds {
                if self.isSocketClosed(fd) {
                    stalePermissionIds.append(id)
                    close(fd)
                }
            }

            // 检查提问请求的 socket 是否还有效
            for (id, fd) in self.questionFds {
                if self.isSocketClosed(fd) {
                    staleQuestionIds.append(id)
                    close(fd)
                }
            }

            // 清理失效的请求
            for id in stalePermissionIds {
                self.permissionFds.removeValue(forKey: id)
            }
            for id in staleQuestionIds {
                self.questionFds.removeValue(forKey: id)
            }

            if !stalePermissionIds.isEmpty || !staleQuestionIds.isEmpty {
                DispatchQueue.main.async {
                    self.pendingPermissions.removeAll { stalePermissionIds.contains($0.id) }
                    self.pendingQuestions.removeAll { staleQuestionIds.contains($0.id) }
                    NSLog("🧹 清理了 %d 个过期权限请求和 %d 个过期问题（终端已处理）",
                          stalePermissionIds.count, staleQuestionIds.count)
                }
            }
        }
    }

    /// 使用 poll 检测 socket 是否已关闭
    private func isSocketClosed(_ fd: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        let result = poll(&pfd, 1, 0) // 非阻塞检查

        if result > 0 {
            // 检查是否有挂断或错误事件
            if (pfd.revents & Int16(POLLHUP)) != 0 || (pfd.revents & Int16(POLLERR)) != 0 {
                return true
            }
            // 如果可读，尝试 peek 检测是否是 EOF
            if (pfd.revents & Int16(POLLIN)) != 0 {
                var buf: CChar = 0
                let n = recv(fd, &buf, 1, MSG_PEEK | MSG_DONTWAIT)
                if n == 0 {
                    // EOF - 对端已关闭
                    return true
                }
            }
        }
        return false
    }

    func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(path)
    }

    // MARK: - 清除会话的所有待处理请求

    /// 当会话被中断时，清除该会话的所有待处理请求
    func clearRequestsForSession(_ sessionId: String) {
        responseQueue.async { [weak self] in
            guard let self = self else { return }

            // 找出该会话的所有权限请求
            let permissionIds = self.pendingPermissions
                .filter { $0.sessionId == sessionId }
                .map { $0.id }

            // 找出该会话的所有问题请求
            let questionIds = self.pendingQuestions
                .filter { $0.sessionId == sessionId }
                .map { $0.id }

            // 关闭并清理权限请求的 socket
            for id in permissionIds {
                if let fd = self.permissionFds[id] {
                    close(fd)
                    self.permissionFds.removeValue(forKey: id)
                }
            }

            // 关闭并清理问题请求的 socket
            for id in questionIds {
                if let fd = self.questionFds[id] {
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
            guard let fd = self.permissionFds[requestId] else {
                print("[Socket] No FD found for: \(requestId)")
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

            close(fd)
            self.permissionFds.removeValue(forKey: requestId)

            DispatchQueue.main.async {
                self.pendingPermissions.removeAll { $0.id == requestId }
            }
        }
    }

    // MARK: - 响应问答请求

    func respondQuestion(requestId: String, answer: String) {
        responseQueue.async { [weak self] in
            guard let fd = self?.questionFds[requestId] else { return }

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

            close(fd)
            self?.questionFds.removeValue(forKey: requestId)

            DispatchQueue.main.async {
                self?.pendingQuestions.removeAll { $0.id == requestId }
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

            // AskUserQuestion 应该作为提问处理，不是权限申请
            if tool == "AskUserQuestion" {
                let questions = inputData["questions"] as? [[String: Any]] ?? []
                let request = AskRequest(
                    id: UUID().uuidString,
                    sessionId: sessionId,
                    questions: questions,
                    timestamp: Date()
                )
                questionFds[request.id] = fd
                DispatchQueue.main.async { [weak self] in
                    self?.pendingQuestions.append(request)
                    self?.onAskRequest?(request)
                }
                return
            }

            // 使用 session_id + tool + input hash 来去重
            let inputHash = (try? JSONSerialization.data(withJSONObject: inputData))?.hashValue ?? 0
            let dedupeKey = "\(sessionId)-\(tool)-\(inputHash)"

            let request = PermissionRequest(
                id: dedupeKey,
                sessionId: sessionId,
                tool: tool,
                input: inputData,
                timestamp: Date()
            )

            // 检查是否已存在相同请求
            if permissionFds[request.id] != nil {
                close(fd)
                return
            }

            permissionFds[request.id] = fd

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !self.pendingPermissions.contains(where: { $0.id == request.id }) {
                    self.pendingPermissions.append(request)
                    self.onPermissionRequest?(request)
                }
            }

        case "ask":
            let questions = json["questions"] as? [[String: Any]] ?? []
            NSLog("📥 收到 ask 请求, questions: %d", questions.count)

            let request = AskRequest(
                id: UUID().uuidString,
                sessionId: json["session_id"] as? String ?? "",
                questions: questions,
                timestamp: Date()
            )

            NSLog("📥 AskRequest firstQuestion: %@, options: %@", request.firstQuestion, request.options.joined(separator: ", "))

            questionFds[request.id] = fd

            DispatchQueue.main.async { [weak self] in
                self?.pendingQuestions.append(request)
                NSLog("📥 pendingQuestions count: %d", self?.pendingQuestions.count ?? 0)
                self?.onAskRequest?(request)
            }

        default:
            close(fd)
        }
    }
}
