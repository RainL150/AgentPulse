import SwiftUI

struct MonitorView: View {
    @EnvironmentObject var monitor: SessionMonitor
    @ObservedObject var socketServer: SocketServer
    @ObservedObject var settings: AppSettings
    let onOpenSettings: () -> Void
    @State private var selectedSessionId: String?

    // 获取指定会话的待审批权限
    func permissionsForSession(_ sessionId: String) -> [PermissionRequest] {
        socketServer.pendingPermissions.filter { $0.sessionId == sessionId }
    }

    // 获取指定会话的待回答问题
    func questionsForSession(_ sessionId: String) -> [AskRequest] {
        socketServer.pendingQuestions.filter { $0.sessionId == sessionId }
    }

    // 获取没有匹配会话的权限请求（孤立请求）
    var orphanedPermissions: [PermissionRequest] {
        let sessionIds = Set(monitor.sessions.map { $0.id })
        return socketServer.pendingPermissions.filter { !sessionIds.contains($0.sessionId) }
    }

    // 获取没有匹配会话的问题请求（孤立问题）
    var orphanedQuestions: [AskRequest] {
        let sessionIds = Set(monitor.sessions.map { $0.id })
        return socketServer.pendingQuestions.filter { !sessionIds.contains($0.sessionId) }
    }

    var visibleSessions: [Session] {
        // 按最后更新时间排序，同时显示活跃和最近的会话
        let sorted = monitor.sessions.sorted { $0.lastUpdate > $1.lastUpdate }
        // 显示所有活跃会话 + 最近更新的会话（最多显示15个）
        return Array(sorted.prefix(15))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HeaderView(activeCount: monitor.activeCount, pendingCount: socketServer.pendingPermissions.count)

            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    if monitor.sessions.isEmpty && socketServer.pendingPermissions.isEmpty && socketServer.pendingQuestions.isEmpty {
                        EmptyStateView()
                    } else {
                        SessionListSection(
                            sessions: visibleSessions,
                            selectedSessionId: selectedSessionId,
                            permissionsForSession: permissionsForSession,
                            questionsForSession: questionsForSession,
                            onSelect: { session in
                                selectedSessionId = selectedSessionId == session.id ? nil : session.id
                            },
                            onJump: { session in
                                TerminalJumper.jump(to: session.id, cwd: session.cwd)
                            },
                            onRemove: { session in
                                SessionMonitor.shared.removeSession(id: session.id)
                            },
                            onApprove: { socketServer.respondPermission(requestId: $0, approved: true) },
                            onDeny: { socketServer.respondPermission(requestId: $0, approved: false) },
                            onAnswer: { id, answer in
                                socketServer.respondQuestion(requestId: id, answer: answer)
                            }
                        )

                        // 孤立的权限请求（没有匹配到会话的）
                        if !orphanedPermissions.isEmpty {
                            OrphanedPermissionsView(
                                permissions: orphanedPermissions,
                                onApprove: { socketServer.respondPermission(requestId: $0, approved: true) },
                                onDeny: { socketServer.respondPermission(requestId: $0, approved: false) }
                            )
                        }

                        // 孤立的问题请求（没有匹配到会话的）
                        if !orphanedQuestions.isEmpty {
                            OrphanedQuestionsView(
                                questions: orphanedQuestions,
                                onAnswer: { id, answer in
                                    socketServer.respondQuestion(requestId: id, answer: answer)
                                }
                            )
                        }
                    }
                }
            }
            .frame(maxHeight: 500)
            .onAppear {
                if selectedSessionId == nil {
                    selectedSessionId = nil
                }
            }
            .onChange(of: monitor.sessions.map(\.id)) { _ in
                if let selectedSessionId,
                   !visibleSessions.contains(where: { $0.id == selectedSessionId }) {
                    self.selectedSessionId = nil
                }
            }

            Divider()

            // 底部操作栏
            FooterView(settings: settings, onOpenSettings: onOpenSettings)
        }
        .frame(width: 480)
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.97),
                    Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.99)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .preferredColorScheme(.dark)
    }
}

struct SessionListSection: View {
    let sessions: [Session]
    let selectedSessionId: String?
    let permissionsForSession: (String) -> [PermissionRequest]
    let questionsForSession: (String) -> [AskRequest]
    let onSelect: (Session) -> Void
    let onJump: (Session) -> Void
    let onRemove: (Session) -> Void
    let onApprove: (String) -> Void
    let onDeny: (String) -> Void
    let onAnswer: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("会话")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.65))
                .padding(.horizontal, 12)
                .padding(.top, 12)

            ForEach(sessions) { session in
                VStack(spacing: 0) {
                    SessionRowView(
                        session: session,
                        isExpanded: selectedSessionId == session.id,
                        pendingPermissions: permissionsForSession(session.id),
                        pendingQuestions: questionsForSession(session.id),
                        onToggleExpand: {
                            onSelect(session)
                        },
                        onJump: {
                            onJump(session)
                        },
                        onRemove: {
                            onRemove(session)
                        }
                    )

                    if selectedSessionId == session.id {
                        SelectedSessionSection(
                            session: session,
                            pendingPermissions: permissionsForSession(session.id),
                            pendingQuestions: questionsForSession(session.id),
                            onApprove: onApprove,
                            onDeny: onDeny,
                            onAnswer: onAnswer
                        )
                    }
                }
            }
        }
    }
}

struct SelectedSessionSection: View {
    @ObservedObject var session: Session
    let pendingPermissions: [PermissionRequest]
    let pendingQuestions: [AskRequest]
    let onApprove: (String) -> Void
    let onDeny: (String) -> Void
    let onAnswer: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !pendingPermissions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(pendingPermissions) { perm in
                        InlinePermissionCard(
                            permission: perm,
                            onApprove: { onApprove(perm.id) },
                            onDeny: { onDeny(perm.id) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            if !pendingQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(pendingQuestions) { q in
                        InlineQuestionCard(
                            question: q,
                            onAnswer: { answer in onAnswer(q.id, answer) }
                        )
                    }
                }
                .padding(.horizontal, 12)
            }

            SessionDetailView(session: session)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background(Color.white.opacity(0.02))
    }
}

// MARK: - Header

struct HeaderView: View {
    let activeCount: Int
    var pendingCount: Int = 0

    var body: some View {
        HStack {
            Image(systemName: "cpu")
                .foregroundColor(.white)
            Text("AgentPulse")
                .font(.headline)
                .foregroundColor(.white)
            Spacer()
            if pendingCount > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    Text("\(pendingCount) 待审批")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            if activeCount > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("\(activeCount) 活跃")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
    }
}

// MARK: - Orphaned Permissions (没有匹配会话的请求)

struct OrphanedPermissionsView: View {
    let permissions: [PermissionRequest]
    let onApprove: (String) -> Void
    let onDeny: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                Text("待处理请求")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
                Spacer()
            }

            ForEach(permissions) { perm in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: perm.icon)
                            .foregroundColor(.orange)
                        Text(perm.tool)
                            .font(.system(size: 11, weight: .medium))
                        Spacer()

                        HStack(spacing: 4) {
                            Button(action: { onDeny(perm.id) }) {
                                Text("拒绝")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.red)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)

                            Button(action: { onApprove(perm.id) }) {
                                Text("批准")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.green)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text(perm.summary)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
    }
}

// MARK: - Orphaned Questions (没有匹配会话的问题)

struct OrphanedQuestionsView: View {
    let questions: [AskRequest]
    let onAnswer: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundColor(.blue)
                Text("待回答问题")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.blue)
                Spacer()
            }

            ForEach(questions) { q in
                VStack(alignment: .leading, spacing: 6) {
                    Text(q.firstQuestion)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)

                    // 选项按钮
                    HStack(spacing: 6) {
                        ForEach(q.options, id: \.self) { option in
                            Button(action: { onAnswer(q.id, option) }) {
                                Text(option)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.blue)
                                    .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.1))
    }
}

// MARK: - Pending Permissions

struct PendingPermissionsView: View {
    let permissions: [PermissionRequest]
    let onApprove: (String) -> Void
    let onDeny: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                Text("等待审批")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
                Spacer()
                Text("\(permissions.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange)
                    .cornerRadius(8)
            }

            ForEach(permissions) { perm in
                PermissionCard(
                    permission: perm,
                    onApprove: { onApprove(perm.id) },
                    onDeny: { onDeny(perm.id) }
                )
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
    }
}

struct PermissionCard: View {
    let permission: PermissionRequest
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: toolIcon)
                    .foregroundColor(.primary)
                Text(permission.tool)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(permission.sessionId.prefix(6))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // 摘要
            Text(permission.summary)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)

            // 详情（直接显示）
            if !permission.detail.isEmpty {
                Text(permission.detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(8)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(4)
            }

            HStack(spacing: 8) {
                Button(action: { onDeny() }) {
                    Text("拒绝")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(action: { onApprove() }) {
                    Text("批准")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.green)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    var toolIcon: String {
        switch permission.tool {
        case "Bash": return "terminal"
        case "Edit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Read": return "doc.text"
        default: return "wrench"
        }
    }
}

// MARK: - Pending Questions

struct PendingQuestionsView: View {
    let questions: [AskRequest]
    let onAnswer: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundColor(.blue)
                Text("等待回答")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.blue)
                Spacer()
            }

            ForEach(questions) { q in
                QuestionCard(
                    question: q,
                    onAnswer: { answer in onAnswer(q.id, answer) }
                )
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.1))
    }
}

struct QuestionCard: View {
    let question: AskRequest
    let onAnswer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.firstQuestion)
                .font(.system(size: 12))
                .lineLimit(3)

            // 选项按钮
            FlowLayout(spacing: 6) {
                ForEach(question.options, id: \.self) { option in
                    Button(action: { onAnswer(option) }) {
                        Text(option)
                            .font(.system(size: 11))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Flow Layout (for options)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("暂无活跃会话")
                .foregroundColor(.secondary)
            Text("启动 Claude Code 后自动显示")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Footer

struct FooterView: View {
    @ObservedObject var settings: AppSettings
    let onOpenSettings: () -> Void

    var body: some View {
        HStack {
            Button(action: { TerminalJumper.jumpToLatest() }) {
                Label("跳转终端", systemImage: "terminal")
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.72))

            Spacer()

            Button(action: onOpenSettings) {
                Label(settings.islandEnabled ? "灵动岛已开" : "设置", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .foregroundColor(settings.islandEnabled ? .white : .white.opacity(0.72))

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("退出", systemImage: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.72))
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
    }
}
