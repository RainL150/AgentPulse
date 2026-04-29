import SwiftUI

struct IslandView: View {
    @EnvironmentObject var monitor: SessionMonitor
    @ObservedObject var socketServer: SocketServer
    @ObservedObject var settings: AppSettings
    @ObservedObject var overlayState: IslandOverlayState
    @ObservedObject var tokenService = TokenUsageService.shared
    let onApprove: (String) -> Void
    let onDeny: (String) -> Void
    let onAnswer: (String, String) -> Void
    let onJump: (String, String) -> Void
    let onOpenPanel: () -> Void
    let onOpenSettings: () -> Void

    @State private var expandedSessionIds: Set<String> = []
    @State private var expandedToolFlowIds: Set<String> = []
    @State private var collapseWorkItem: DispatchWorkItem?

    private var currentPermission: PermissionRequest? {
        if let focusedId = overlayState.focusedPermissionId {
            return socketServer.pendingPermissions.first(where: { $0.id == focusedId })
        }
        return socketServer.pendingPermissions.first
    }

    private var currentQuestion: AskRequest? {
        if let focusedId = overlayState.focusedQuestionId {
            return socketServer.pendingQuestions.first(where: { $0.id == focusedId })
        }
        return socketServer.pendingQuestions.first
    }

    private var prioritizedSessions: [Session] {
        let sessions = monitor.sessions.sorted { $0.lastUpdate > $1.lastUpdate }
        let active = sessions.filter(\.isActive)
        let source = active.isEmpty ? sessions : active
        return Array(source.prefix(6))
    }

    private var selectedSession: Session? {
        guard let selectedId = overlayState.selectedSessionId else { return nil }
        return monitor.sessions.first(where: { $0.id == selectedId })
    }

    private var hasAttention: Bool {
        !socketServer.pendingPermissions.isEmpty || !socketServer.pendingQuestions.isEmpty
    }

    private var hasNotification: Bool {
        overlayState.completionNotification != nil
    }

    private func session(for notification: CompletionNotification) -> Session? {
        monitor.sessions.first(where: { $0.id == notification.sessionId })
    }

    // 有待处理权限/问题的会话
    private var sessionWithAttention: Session? {
        // 优先显示有权限请求的会话
        if let permission = socketServer.pendingPermissions.first,
           let session = monitor.sessions.first(where: { $0.id == permission.sessionId }) {
            return session
        }
        // 其次显示有问题的会话
        if let question = socketServer.pendingQuestions.first,
           let session = monitor.sessions.first(where: { $0.id == question.sessionId }) {
            return session
        }
        return nil
    }

    // 没有匹配到会话的问题
    private var orphanedQuestions: [AskRequest] {
        let sessionIds = Set(monitor.sessions.map { $0.id })
        return socketServer.pendingQuestions.filter { !sessionIds.contains($0.sessionId) }
    }

    // 没有匹配到会话的权限请求
    private var orphanedPermissions: [PermissionRequest] {
        let sessionIds = Set(monitor.sessions.map { $0.id })
        return socketServer.pendingPermissions.filter { !sessionIds.contains($0.sessionId) }
    }

    private var shouldReveal: Bool {
        // 用户悬停、主动展开、或有通知时显示
        // 有审批时不强制显示，让用户可以隐藏
        overlayState.isHovered || overlayState.isPinnedExpanded || hasNotification
    }

    private var isExpanded: Bool {
        overlayState.isPinnedExpanded || (hasAttention && settings.islandAutoExpand)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // 收起状态：小胶囊
            if !shouldReveal {
                capsuleView
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }

            // 通知气泡
            if hasNotification, let notification = overlayState.completionNotification {
                notificationBubble(notification)
                    .id(notification.id)
                    .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
                    .onHover { hovering in
                        overlayState.setNotificationHovered(hovering)
                    }
            }

            // 展开状态：完整面板
            if shouldReveal && !hasNotification {
                islandBody
                    .frame(minHeight: 200, maxHeight: 600)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
                    .onHover { hovering in
                        if hovering {
                            collapseWorkItem?.cancel()
                            collapseWorkItem = nil
                            overlayState.isHovered = true
                        } else {
                            // 允许随时隐藏，包括有待审批时
                            collapseWorkItem?.cancel()
                            let delay = expandedSessionIds.isEmpty ? 0.3 : 0.8
                            let workItem = DispatchWorkItem { [weak overlayState] in
                                guard let overlayState = overlayState else { return }
                                overlayState.isHovered = false
                                overlayState.collapse()
                            }
                            collapseWorkItem = workItem
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
                        }
                    }
                    .onChange(of: expandedSessionIds) { _ in
                        collapseWorkItem?.cancel()
                        collapseWorkItem = nil
                    }
                    .onChange(of: hasAttention) { newValue in
                        if newValue, let session = sessionWithAttention {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                expandedSessionIds.removeAll()
                                expandedSessionIds.insert(session.id)
                            }
                        }
                    }
                    .onChange(of: socketServer.pendingPermissions.count) { _ in
                        if let session = sessionWithAttention {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                expandedSessionIds.removeAll()
                                expandedSessionIds.insert(session.id)
                            }
                        }
                    }
                    .onChange(of: socketServer.pendingQuestions.count) { _ in
                        if let session = sessionWithAttention {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                expandedSessionIds.removeAll()
                                expandedSessionIds.insert(session.id)
                            }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: shouldReveal)
        .animation(.easeInOut(duration: 0.25), value: hasNotification)
    }

    // 收起状态的胶囊视图
    private var capsuleView: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(Color.white.opacity(0.6))
                .frame(width: 100, height: 6)
            Spacer()
        }
        .frame(width: 280, height: 50)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                collapseWorkItem?.cancel()
                collapseWorkItem = nil
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    overlayState.isHovered = true
                }
            }
        }
    }

    /// 灵动岛弹出式通知气泡
    private func notificationBubble(_ notification: CompletionNotification) -> some View {
        let pendingCount = overlayState.pendingNotificationCount
        let isInterrupted = notification.type == .interrupted
        let accentColor = isInterrupted ? Theme.warning : Theme.success
        let iconName = isInterrupted ? "stop.fill" : "checkmark"
        let badgeText = isInterrupted ? "已中断" : "完成"

        return VStack(alignment: .leading, spacing: 12) {
            // 顶部：会话名称 + 关闭
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: isInterrupted
                                    ? [Theme.warning, Color(hex: "D97706")]
                                    : [Theme.success, Color(hex: "059669")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)
                    Image(systemName: iconName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }

                // 会话名称
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(notification.sessionName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                        TagBadge(text: badgeText, color: accentColor, style: .subtle)
                        // 显示待处理通知数
                        if pendingCount > 0 {
                            Text("+\(pendingCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                Button(action: {
                    overlayState.dismissCompletion()
                }) {
                    Image(systemName: pendingCount > 0 ? "chevron.right" : "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(pendingCount > 0 ? "下一条通知" : "关闭")
            }

            let matchedSession = session(for: notification)

            HStack(spacing: 10) {
                Button(action: {
                    TerminalJumper.jumpToEnsoAI(cwd: matchedSession?.cwd)
                    overlayState.dismissCompletion()
                }) {
                    Label("打开 EnsoAI", systemImage: "wand.and.stars")
                        .modifier(IslandSecondaryButtonStyle())
                }
                .buttonStyle(.plain)
                .help("打开 EnsoAI")

                Button(action: {
                    overlayState.dismissCompletion()
                    if let matchedSession {
                        TerminalJumper.jump(
                            to: matchedSession.id,
                            cwd: matchedSession.cwd,
                            agent: matchedSession.source
                        )
                    } else {
                        TerminalJumper.jump(to: notification.sessionId, cwd: nil)
                    }
                }) {
                    Label("跳转终端", systemImage: "terminal")
                        .modifier(IslandSecondaryButtonStyle())
                }
                .buttonStyle(.plain)
                .help("跳转终端")

                Spacer(minLength: 0)
            }

            // 用户问题
            if !notification.prompt.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.info.opacity(0.8))
                    Text(notification.prompt)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                }
            }

            // AI 总结 / 中断原因
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isInterrupted ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(accentColor)
                Text(notification.summary)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.bgPrimary.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [accentColor.opacity(0.5), accentColor.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .shadow(color: Color.black.opacity(0.4), radius: 30, x: 0, y: 15)
        .contentShape(Rectangle())
        .onTapGesture {
            let sessionId = notification.sessionId
            overlayState.dismissCompletion()
            expandedSessionIds.removeAll()
            expandedSessionIds.insert(sessionId)
            overlayState.selectedSessionId = sessionId
            overlayState.setNotificationHovered(true)
        }
    }

    private var islandBody: some View {
        currentExpandedContent
            .padding(16)
            .frame(width: 560)
            .background(GlassBackground(cornerRadius: 24, opacity: 0.92))
            .shadow(color: Color.black.opacity(0.5), radius: 40, x: 0, y: 20)
            .shadow(color: Theme.primary.opacity(0.1), radius: 60, x: 0, y: 30)
    }

    @ViewBuilder
    private var currentExpandedContent: some View {
        sessionListView
    }

    private var hoverHotspot: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.015))
                .frame(width: 96, height: 8)
            Capsule()
                .fill(statusColor.opacity(0.22))
                .frame(width: 22, height: 4)
        }
        .frame(width: 180, height: 16)
        .opacity(0.22)
        .contentShape(Rectangle())
        .onHover { hovering in
            overlayState.isHovered = hovering
        }
    }

    // MARK: - 会话列表视图
    private var sessionListView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 头部区域
            HStack(alignment: .center) {
                HStack(spacing: 10) {
                    PulseIconView(size: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("AgentPulse")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Theme.textPrimary)
                        HStack(spacing: 6) {
                            StatusDot(color: statusColor, size: 6, animated: monitor.activeCount > 0)
                            Text("\(monitor.activeCount) 活跃")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }

                Spacer()

                if tokenService.totalUsage.total > 0 {
                    TokenDisplay(usage: tokenService.totalUsage, compact: true)
                }

                headerActions
            }

            SectionDivider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    // 只有展开的会话才独占显示，否则显示全部列表
                    if let expandedId = expandedSessionIds.first,
                       let expandedSession = prioritizedSessions.first(where: { $0.id == expandedId }) {
                        // 展开的会话独占显示
                        sessionCard(expandedSession)
                    } else {
                        // 显示全部列表
                        ForEach(orphanedQuestions) { question in
                            orphanedQuestionCard(question)
                        }
                        ForEach(orphanedPermissions) { permission in
                            orphanedPermissionCard(permission)
                        }
                        if prioritizedSessions.isEmpty && orphanedQuestions.isEmpty && orphanedPermissions.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(prioritizedSessions) { session in
                                sessionCard(session)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 会话卡片（支持展开/折叠）
    private func sessionCard(_ session: Session) -> some View {
        let sessionPermissions = socketServer.pendingPermissions.filter { $0.sessionId == session.id }
        let sessionQuestions = socketServer.pendingQuestions.filter { $0.sessionId == session.id }
        let hasAttention = !sessionPermissions.isEmpty || !sessionQuestions.isEmpty
        let hasSummary = session.currentRequest?.summary != nil
        // 有待处理时默认展开，但用户可以手动折叠
        let isExpanded = expandedSessionIds.contains(session.id)

        let dotColor: Color = {
            if hasAttention { return Theme.warning }
            if hasSummary { return Theme.secondary }
            switch session.state {
            case .running: return Theme.success
            case .idle: return Color(hex: "EAB308")
            case .stopped: return Theme.textMuted
            case .expired: return Theme.textMuted.opacity(0.5)
            }
        }()

        return VStack(alignment: .leading, spacing: 0) {
            // 会话头部（点击展开/折叠）
            HStack(spacing: 12) {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        if expandedSessionIds.contains(session.id) {
                            expandedSessionIds.remove(session.id)
                        } else {
                            expandedSessionIds.removeAll()
                            expandedSessionIds.insert(session.id)
                        }
                    }
                }) {
                    HStack(spacing: 12) {
                        StatusDot(color: dotColor, size: 10, animated: session.state == .running && !hasSummary)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(session.cwd.isEmpty ? String(session.id.prefix(8)) : (session.cwd as NSString).lastPathComponent)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.textPrimary)
                                sourcePill(session.source)
                                if hasSummary && !hasAttention {
                                    TagBadge(text: "完成", color: Theme.secondary, style: .subtle)
                                }
                                if !sessionPermissions.isEmpty {
                                    HStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.shield.fill")
                                            .font(.system(size: 9))
                                        Text("待审批")
                                    }
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Theme.warning)
                                    .clipShape(Capsule())
                                } else if !sessionQuestions.isEmpty {
                                    HStack(spacing: 4) {
                                        Image(systemName: "questionmark.circle.fill")
                                            .font(.system(size: 9))
                                        Text("待回答")
                                    }
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Theme.info)
                                    .clipShape(Capsule())
                                }
                            }
                            if !isExpanded {
                                Text(session.currentRequest?.prompt ?? "等待指令")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textSecondary)
                                    .lineLimit(1)
                            } else if !session.cwd.isEmpty {
                                Text(session.cwd)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.textMuted)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                let usage = tokenService.usage(for: session.id)
                if usage.total > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 9))
                        Text(usage.formatted)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.12))
                    .clipShape(Capsule())
                }

                Text(relativeTime(session.lastUpdate))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textMuted)

                if !session.cwd.isEmpty {
                    Button(action: { TerminalJumper.jumpToEnsoAI(cwd: session.cwd) }) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.info)
                            .frame(width: 28, height: 28)
                            .background(Theme.bgTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("在此目录启动 EnsoAI")

                    Button(action: { onJump(session.id, session.cwd) }) {
                        Image(systemName: "terminal")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(Theme.bgTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("跳转到终端会话")
                }

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            // 折叠时的预览信息
            if !isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    // 待审批/待回答预览
                    if let permission = sessionPermissions.first {
                        HStack(spacing: 8) {
                            Image(systemName: permission.icon)
                                .font(.system(size: 10))
                                .foregroundColor(Theme.warning)
                            Text("\(permission.tool): \(permission.summary)")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.warning)
                                .lineLimit(1)
                        }
                    } else if let question = sessionQuestions.first {
                        HStack(spacing: 8) {
                            Image(systemName: "questionmark.bubble")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.info)
                            Text(question.firstQuestion)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.info)
                                .lineLimit(1)
                        }
                    } else {
                        // 任务进度预览
                        if !session.tasks.isEmpty {
                            let completed = session.tasks.filter { $0.status == .completed }.count
                            let inProgress = session.tasks.first { $0.status == .inProgress }
                            HStack(spacing: 8) {
                                Image(systemName: "checklist")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.warning)
                                if let current = inProgress {
                                    Text(current.activeForm ?? current.subject)
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.warning)
                                        .lineLimit(1)
                                }
                                Spacer()
                                ProgressView(value: Double(completed), total: Double(session.tasks.count))
                                    .progressViewStyle(LinearProgressViewStyle(tint: Theme.warning))
                                    .frame(width: 40)
                                Text("\(completed)/\(session.tasks.count)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                        // 总结或最近工具预览
                        if let summary = session.currentRequest?.summary {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.success)
                                Text(summary.result)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.success)
                                    .lineLimit(1)
                            }
                        } else if let tool = session.currentRequest?.tools.last {
                            HStack(spacing: 8) {
                                ToolIcon(tool: tool.tool, size: 20)
                                Text(tool.fullDetail.isEmpty ? tool.tool : tool.fullDetail)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            // 展开时的详细内容
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    // 权限请求
                    ForEach(sessionPermissions) { permission in
                        inlinePermissionCard(permission)
                    }
                    // 问题
                    ForEach(sessionQuestions) { question in
                        inlineQuestionCard(question)
                    }
                    // 任务列表
                    if !session.tasks.isEmpty {
                        taskListView(session.tasks)
                    }
                    // 用户请求
                    if let request = session.currentRequest {
                        simpleRequestCard(request.prompt)
                    }
                    // 执行流
                    if let tools = session.currentRequest?.tools, !tools.isEmpty {
                        inlineToolFlow(sessionId: session.id, tools: tools)
                    }
                    // AI 总结
                    if let summary = session.currentRequest?.summary {
                        simpleSummaryCard(summary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.bgSecondary.opacity(isExpanded ? 0.7 : 0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isExpanded ? Theme.primary.opacity(0.2) : Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - 简化的用户请求卡片
    private func simpleRequestCard(_ prompt: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 11))
                .foregroundColor(Theme.info)
            Text(prompt)
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgTertiary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 简化的 AI 总结卡片
    private func simpleSummaryCard(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 流程（如果有）
            if !summary.flow.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.accent)
                    Text(summary.flow)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.accent)
                        .lineLimit(2)
                }
            }
            // 结果
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.success)
                Text(summary.result)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.success)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.success.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(Theme.textMuted)
            Text("暂无运行中的会话")
                .font(.system(size: 13))
                .foregroundColor(Theme.textTertiary)
            Text("启动 Claude Code 开始工作")
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // 孤立问题卡片
    private func orphanedQuestionCard(_ question: AskRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundColor(.blue)
                Text("需要回答")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.blue)
                Spacer()
                Text(String(question.sessionId.prefix(8)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }

            Text(question.firstQuestion)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            // 选项按钮
            HStack(spacing: 8) {
                ForEach(question.options, id: \.self) { option in
                    Button(action: { onAnswer(question.id, option) }) {
                        Text(option)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // 孤立权限请求卡片
    private func orphanedPermissionCard(_ permission: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题行
            HStack(spacing: 8) {
                Image(systemName: permission.icon)
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
                    .frame(width: 32, height: 32)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(8)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("权限申请")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.orange)
                        Text(permission.tool)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.orange.opacity(0.7))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(4)
                    }
                    Text(permission.summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(2)
                }
                Spacer()
                Text(String(permission.sessionId.prefix(8)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
            }

            // 详细信息区域
            if !permission.detail.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(permission.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
                .padding(10)
                .background(Color.black.opacity(0.4))
                .cornerRadius(8)
            }

            // 操作按钮
            HStack(spacing: 10) {
                Button(action: { onDeny(permission.id) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("拒绝")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.85))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button(action: { onApprove(permission.id) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("批准")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.85))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    private func inlineToolFlow(sessionId: String, tools: [ToolCall]) -> some View {
        let isToolExpanded = expandedToolFlowIds.contains(sessionId)

        return VStack(alignment: .leading, spacing: 10) {
            // 标题行
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Theme.bgTertiary)
                        .frame(width: 24, height: 24)
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                Text("执行流")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                TagBadge(text: "\(tools.count) 操作", color: Theme.textMuted, style: .subtle)
                Image(systemName: isToolExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                    .rotationEffect(.degrees(isToolExpanded ? 0 : 0))
                    .animation(.spring(response: 0.3), value: isToolExpanded)
            }

            if isToolExpanded {
                // 展开显示详细列表（时间正序：旧的在上，新的在下）
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 6) {
                            if tools.count > 15 {
                                HStack(spacing: 6) {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 10))
                                    Text("还有 \(tools.count - 15) 个旧操作")
                                        .font(.system(size: 10))
                                }
                                .foregroundColor(Theme.textMuted)
                                .padding(.vertical, 4)
                            }
                            ForEach(Array(tools.suffix(15).enumerated()), id: \.element.id) { index, tool in
                                HStack(spacing: 10) {
                                    // 工具图标
                                    ToolIcon(tool: tool.tool, size: 24)

                                    // 工具名称和详情
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.tool)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(tool.status == .failed ? Theme.error : Theme.textPrimary)
                                        Text(tool.fullDetail.isEmpty ? tool.detail : tool.fullDetail)
                                            .font(.system(size: 10))
                                            .foregroundColor(Theme.textSecondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    // 状态和耗时
                                    HStack(spacing: 6) {
                                        if tool.status == .failed {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 10))
                                                .foregroundColor(Theme.error)
                                        }
                                        if let duration = tool.durationText {
                                            Text(duration)
                                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                                .foregroundColor(Theme.textMuted)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Theme.bgTertiary)
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                                .id("expanded-\(tool.id)")
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    .onAppear {
                        // 滚动到最新（底部）
                        if let lastTool = tools.suffix(15).last {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("expanded-\(lastTool.id)", anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            } else {
                // 折叠显示图标流（时间正序：旧的在左，新的在右）
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if tools.count > 6 {
                                HStack(spacing: 4) {
                                    Text("...\(tools.count - 6)")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(Theme.textMuted)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundColor(Theme.textMuted.opacity(0.5))
                                }
                            }
                            ForEach(Array(tools.suffix(6).enumerated()), id: \.element.id) { index, tool in
                                if index > 0 {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundColor(Theme.textMuted.opacity(0.5))
                                }
                                VStack(spacing: 4) {
                                    ToolIcon(tool: tool.tool, size: 28)
                                    Text(toolFlowLabel(tool))
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(Theme.textSecondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: 70)
                                }
                                .id(tool.id)
                            }
                            // 锚点用于滚动到最右
                            Color.clear
                                .frame(width: 1)
                                .id("scroll-anchor-\(sessionId)")
                        }
                    }
                    .onAppear {
                        // 初始滚动到最右
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo("scroll-anchor-\(sessionId)", anchor: .trailing)
                        }
                    }
                    .onChange(of: tools.count) { _ in
                        // 工具数量变化时滚动到最右
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("scroll-anchor-\(sessionId)", anchor: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.bgTertiary.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.textMuted.opacity(0.1), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                if expandedToolFlowIds.contains(sessionId) {
                    expandedToolFlowIds.remove(sessionId)
                } else {
                    expandedToolFlowIds.insert(sessionId)
                }
            }
        }
    }

    private func expandedSessionDetail(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题行
            HStack(alignment: .top, spacing: 10) {
                Button(action: { overlayState.showOverview() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(session.cwd.isEmpty ? String(session.id.prefix(8)) : (session.cwd as NSString).lastPathComponent)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        sourcePill(session.source)
                    }
                    Text(session.cwd.isEmpty ? "会话 ID: \(session.id)" : session.cwd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.58))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if !session.cwd.isEmpty {
                    Button(action: { TerminalJumper.jumpToEnsoAI(cwd: session.cwd) }) {
                        Label("EnsoAI", systemImage: "wand.and.stars")
                            .modifier(IslandSecondaryButtonStyle())
                    }
                    .buttonStyle(.plain)

                    Button(action: { onJump(session.id, session.cwd) }) {
                        Label("跳转", systemImage: "terminal")
                            .modifier(IslandSecondaryButtonStyle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // 当前请求
            if let request = session.currentRequest {
                detailBlock(title: "当前请求", systemImage: "bubble.left.fill", tint: .blue) {
                    Text(request.prompt)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(4)
                }
            }

            // 执行流（图标流样式）
            if let tools = session.currentRequest?.tools, !tools.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                        Text("执行流")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Text("\(tools.count) 操作")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }

                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                if tools.count > 8 {
                                    Text("...\(tools.count - 8)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.4))
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                                ForEach(Array(tools.suffix(8).enumerated()), id: \.element.id) { index, tool in
                                    if index > 0 {
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 9))
                                            .foregroundColor(.white.opacity(0.3))
                                    }
                                    VStack(spacing: 3) {
                                        Image(systemName: tool.icon)
                                            .font(.system(size: 14))
                                            .foregroundColor(toolColor(tool.tool))
                                            .frame(width: 28, height: 28)
                                            .background(toolColor(tool.tool).opacity(0.15))
                                            .cornerRadius(6)
                                        Text(toolShortName(tool))
                                            .font(.system(size: 8))
                                            .foregroundColor(.white.opacity(0.5))
                                            .lineLimit(1)
                                            .frame(width: 50)
                                    }
                                    .id(tool.id)
                                }
                                Spacer(minLength: 0)
                                    .id("trailing")
                            }
                        }
                        .onAppear {
                            // 默认滚动到最右侧（最新操作）
                            if let lastTool = tools.suffix(8).last {
                                proxy.scrollTo(lastTool.id, anchor: .trailing)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // AI 总结
            if let summary = session.currentRequest?.summary {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.purple)
                        Text("AI 总结")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.purple)
                    }

                    if !summary.flow.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Text("流程")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                                .frame(width: 28, alignment: .leading)
                            Text(summary.flow)
                                .font(.system(size: 11))
                                .foregroundColor(.blue)
                        }
                    }

                    HStack(alignment: .top, spacing: 6) {
                        Text("结果")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 28, alignment: .leading)
                        Text(summary.result)
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // 任务计划
            if !session.tasks.isEmpty {
                taskListView(session.tasks)
            }
        }
    }

    private func expandedPermission(_ permission: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                attentionBackButton

                VStack(alignment: .leading, spacing: 4) {
                    Text("权限申请")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text(permission.summary)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(2)
                }
                Spacer()
                headerActions
            }

            attentionStrip(
                icon: permission.icon,
                tint: .orange,
                title: permission.tool,
                subtitle: permission.detail.isEmpty ? "等待审批" : permission.detail
            )

            HStack(spacing: 8) {
                Button(action: { onDeny(permission.id) }) {
                    Text("拒绝")
                        .modifier(IslandActionButtonStyle(background: Color.red.opacity(0.82)))
                }
                .buttonStyle(.plain)

                Button(action: { onApprove(permission.id) }) {
                    Text("批准")
                        .modifier(IslandActionButtonStyle(background: Color.green.opacity(0.88)))
                }
                .buttonStyle(.plain)

                Spacer()

                if let session = monitor.sessions.first(where: { $0.id == permission.sessionId }), !session.cwd.isEmpty {
                    Button(action: { TerminalJumper.jumpToEnsoAI(cwd: session.cwd) }) {
                        Label("EnsoAI", systemImage: "wand.and.stars")
                            .modifier(IslandSecondaryButtonStyle())
                    }
                    .buttonStyle(.plain)

                    Button(action: { onJump(session.id, session.cwd) }) {
                        Label("跳转终端", systemImage: "terminal")
                            .modifier(IslandSecondaryButtonStyle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func expandedQuestion(_ question: AskRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                attentionBackButton

                VStack(alignment: .leading, spacing: 4) {
                    Text("等待回答")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text(question.firstQuestion)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(3)
                }
                Spacer()
                headerActions
            }

            attentionStrip(
                icon: "questionmark.bubble.fill",
                tint: .blue,
                title: "Ask",
                subtitle: "在灵动岛直接选择答案并返回当前会话。"
            )

            FlowLayout(spacing: 8) {
                ForEach(question.options, id: \.self) { option in
                    Button(action: { onAnswer(question.id, option) }) {
                        Text(option)
                            .modifier(IslandSecondaryButtonStyle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                if let session = monitor.sessions.first(where: { $0.id == question.sessionId }), !session.cwd.isEmpty {
                    Button(action: { TerminalJumper.jumpToEnsoAI(cwd: session.cwd) }) {
                        Label("EnsoAI", systemImage: "wand.and.stars")
                            .modifier(IslandSecondaryButtonStyle())
                    }
                    .buttonStyle(.plain)

                    Button(action: { onJump(session.id, session.cwd) }) {
                        Label("跳转终端", systemImage: "terminal")
                            .modifier(IslandSecondaryButtonStyle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 6) {
            // 点击徽章展开对应会话
            if socketServer.pendingPermissions.count > 0 {
                Button(action: {
                    // 展开有待审批的会话
                    if let permission = socketServer.pendingPermissions.first {
                        expandedSessionIds.removeAll()
                        expandedSessionIds.insert(permission.sessionId)
                    }
                }) {
                    Text("\(socketServer.pendingPermissions.count) 审核")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.18))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if socketServer.pendingQuestions.count > 0 {
                Button(action: {
                    // 展开有待回答的会话
                    if let question = socketServer.pendingQuestions.first {
                        expandedSessionIds.removeAll()
                        expandedSessionIds.insert(question.sessionId)
                    }
                }) {
                    Text("\(socketServer.pendingQuestions.count) 提问")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.18))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Button(action: onOpenPanel) {
                Image(systemName: "rectangle.expand.vertical")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.86))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Button(action: onOpenSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.86))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white.opacity(0.82))
    }

    private var attentionBackButton: some View {
        Button(action: { overlayState.showOverview() }) {
            Image(systemName: "chevron.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var compactSubtitle: String {
        if let permission = currentPermission {
            return "待审核: \(permission.summary)"
        }
        if let question = currentQuestion {
            return "待回答: \(question.firstQuestion)"
        }
        if !prioritizedSessions.isEmpty {
            return "\(prioritizedSessions.count) 个会话运行中"
        }
        return "等待会话启动"
    }

    private var statusColor: Color {
        if currentPermission != nil { return .orange }
        if currentQuestion != nil { return .blue }
        return monitor.activeCount > 0 ? .green : .gray
    }

    private var backgroundView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.92),
                    Color(red: 0.09, green: 0.10, blue: 0.13).opacity(0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.white.opacity(0.10),
                    Color.clear
                ],
                center: .top,
                startRadius: 10,
                endRadius: 220
            )
        }
    }

    private func sessionChip(_ session: Session) -> some View {
        let title = session.cwd.isEmpty ? String(session.id.prefix(4)) : String((session.cwd as NSString).lastPathComponent.prefix(8))
        return Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.86))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
    }

    private func expandedSessionRow(_ session: Session) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(stateColor(session.state))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.cwd.isEmpty ? String(session.id.prefix(8)) : (session.cwd as NSString).lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    sourcePill(session.source)
                }
                Text(session.currentRequest?.prompt ?? "等待下一条指令")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer()

            if socketServer.pendingPermissions.contains(where: { $0.sessionId == session.id }) {
                Text("审批")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange)
            }

            if socketServer.pendingQuestions.contains(where: { $0.sessionId == session.id }) {
                Text("Ask")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.blue)
            }

            Text(relativeTime(session.lastUpdate))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.48))

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.42))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func attentionStrip(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.68))
                    .lineLimit(5)
            }

            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func sourcePill(_ source: SessionAgent) -> some View {
        Text(source.label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(source == .codex ? Color(red: 0.54, green: 0.86, blue: 1.0) : Color(red: 1.0, green: 0.78, blue: 0.52))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
    }

    // MARK: - Task List View

    private func taskListView(_ tasks: [Task]) -> some View {
        let completed = tasks.filter { $0.status == .completed }.count
        let inProgress = tasks.first { $0.status == .inProgress }

        return VStack(alignment: .leading, spacing: 8) {
            // 标题行
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                if let current = inProgress {
                    Text(current.activeForm ?? current.subject)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.orange)
                } else {
                    Text("任务计划")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.orange)
                }
                Spacer()
                Text("\(completed)/\(tasks.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }

            // 任务列表
            VStack(alignment: .leading, spacing: 4) {
                ForEach(tasks) { task in
                    HStack(spacing: 8) {
                        // 状态图标
                        Group {
                            switch task.status {
                            case .completed:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            case .inProgress:
                                Image(systemName: "circle.fill")
                                    .foregroundColor(.orange)
                            case .pending:
                                Image(systemName: "circle")
                                    .foregroundColor(.white.opacity(0.4))
                            }
                        }
                        .font(.system(size: 10))
                        .frame(width: 14)

                        // 任务名称
                        Text(task.subject)
                            .font(.system(size: 11))
                            .foregroundColor(taskTextColor(task.status))
                            .lineLimit(1)
                            .strikethrough(task.status == .completed, color: .white.opacity(0.3))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func taskTextColor(_ status: TaskStatus) -> Color {
        switch status {
        case .completed: return .white.opacity(0.5)
        case .inProgress: return .orange
        case .pending: return .white.opacity(0.7)
        }
    }

    private func detailBlock<Content: View>(title: String, systemImage: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.66))
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = max(0, Int(Date().timeIntervalSince(date)))
        if interval < 60 { return "\(interval)s" }
        if interval < 3600 { return "\(interval / 60)m" }
        return "\(interval / 3600)h"
    }

    private func stateColor(_ state: SessionState) -> Color {
        switch state {
        case .running: return .green
        case .idle: return .yellow
        case .stopped: return Color(white: 0.5)
        case .expired: return Color(white: 0.3)
        }
    }

    private func toolColor(_ tool: String) -> Color {
        switch tool {
        case "Read": return .blue
        case "Edit", "Write": return .orange
        case "Bash": return .green
        case "Grep", "Glob": return .purple
        case "WebSearch", "WebFetch": return .cyan
        case "TaskCreate", "TaskUpdate": return .pink
        case "Task": return .indigo
        case "Skill": return .yellow
        default: return .white.opacity(0.7)
        }
    }

    private func toolShortName(_ tool: ToolCall) -> String {
        let detail = tool.detail
        if !detail.isEmpty {
            return String(detail.prefix(8))
        }
        switch tool.tool {
        case "Bash": return "bash"
        case "Read": return "read"
        case "Edit": return "edit"
        case "Write": return "write"
        case "Grep": return "grep"
        case "Glob": return "glob"
        case "WebSearch": return "search"
        case "WebFetch": return "fetch"
        case "Task": return "task"
        default: return tool.tool.lowercased().prefix(6).description
        }
    }

    // MARK: - 内嵌权限卡片
    private func inlinePermissionCard(_ permission: PermissionRequest) -> some View {
        // 检测是否来自 Codex 会话
        let isCodex = monitor.sessions.first(where: { $0.id == permission.sessionId })?.source == .codex

        return VStack(alignment: .leading, spacing: 10) {
            // 标题行
            HStack(spacing: 8) {
                Image(systemName: permission.icon)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.warning)
                    .frame(width: 32, height: 32)
                    .background(Theme.warning.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(isCodex ? "Codex 请求执行" : "权限申请")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.warning)
                        Text(permission.tool)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.warning.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.warning.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    Text(permission.summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                }
                Spacer()

                // 关闭/跳过按钮
                Button(action: { onDeny(permission.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: 24, height: 24)
                        .background(Theme.bgTertiary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("跳过此请求")
            }

            // 详细信息区域（可滚动）
            if !permission.detail.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(permission.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
                .padding(10)
                .background(Theme.bgPrimary.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // 操作按钮 - Codex 和 Claude Code 使用不同样式
            if isCodex {
                // Codex 风格选项
                VStack(spacing: 8) {
                    Button(action: { onApprove(permission.id) }) {
                        HStack {
                            Text("1.")
                                .foregroundColor(Theme.textMuted)
                            Text("Yes, proceed")
                                .foregroundColor(.white)
                            Spacer()
                            Text("y")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.textMuted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.bgTertiary)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.success.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Theme.success.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .bouncyButton()

                    Button(action: { onDeny(permission.id) }) {
                        HStack {
                            Text("2.")
                                .foregroundColor(Theme.textMuted)
                            Text("No, tell Codex what to do differently")
                                .foregroundColor(.white)
                            Spacer()
                            Text("esc")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.textMuted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.bgTertiary)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.bgTertiary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Theme.textMuted.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .bouncyButton()
                }
            } else {
                // Claude Code 风格按钮
                HStack(spacing: 10) {
                    Button(action: { onDeny(permission.id) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                            Text("拒绝")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Theme.error)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .bouncyButton()

                    Button(action: { onApprove(permission.id) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                            Text("批准")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Theme.success)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .bouncyButton()

                    Spacer()
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.warning.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.warning.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - 内嵌问题卡片
    private func inlineQuestionCard(_ question: AskRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.info)
                    .frame(width: 28, height: 28)
                    .background(Theme.info.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("等待回答")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.info)
                    Text(question.firstQuestion)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()

                // 关闭/跳过按钮
                Button(action: {
                    // 选择 "Other" 跳过该问题
                    onAnswer(question.id, "")
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: 24, height: 24)
                        .background(Theme.bgTertiary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("跳过此问题")
            }

            // 选项按钮
            FlowLayout(spacing: 8) {
                ForEach(question.options, id: \.self) { option in
                    Button(action: { onAnswer(question.id, option) }) {
                        Text(option)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.info.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .bouncyButton()
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.info.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.info.opacity(0.25), lineWidth: 1)
        )
    }

    private func toolFlowLabel(_ tool: ToolCall) -> String {
        // 优先使用 fullDetail（通常包含描述/注释）
        if !tool.fullDetail.isEmpty {
            let desc = tool.fullDetail
            // 如果是 Bash 且有描述，添加 # 前缀
            if tool.tool == "Bash" && !desc.hasPrefix("#") && !desc.hasPrefix("/") && !desc.contains("&&") {
                return "# \(desc)"
            }
            return desc
        }
        // 其次使用 detail
        if !tool.detail.isEmpty {
            return tool.detail
        }
        // 默认显示工具名
        return tool.tool.lowercased()
    }
}

private struct IslandActionButtonStyle: ViewModifier {
    let background: Color

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(background)
            .clipShape(Capsule())
    }
}

private struct IslandSecondaryButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.10))
            .clipShape(Capsule())
    }
}
