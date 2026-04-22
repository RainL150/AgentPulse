import SwiftUI

struct IslandView: View {
    @EnvironmentObject var monitor: SessionMonitor
    @ObservedObject var socketServer: SocketServer
    @ObservedObject var settings: AppSettings
    @ObservedObject var overlayState: IslandOverlayState
    let onApprove: (String) -> Void
    let onDeny: (String) -> Void
    let onAnswer: (String, String) -> Void
    let onJump: (String, String) -> Void
    let onOpenPanel: () -> Void
    let onOpenSettings: () -> Void

    @State private var expandedSessionIds: Set<String> = []
    @State private var expandedToolFlowIds: Set<String> = []

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
        overlayState.isHovered || overlayState.isPinnedExpanded || hasAttention
    }

    private var isExpanded: Bool {
        overlayState.isPinnedExpanded || (hasAttention && settings.islandAutoExpand)
    }

    var body: some View {
        Group {
            if shouldReveal {
                islandBody
                    .frame(width: 520, height: 520)
                    .onHover { hovering in
                        overlayState.isHovered = hovering
                    }
            } else {
                // 收起状态：小胶囊
                HStack {
                    Spacer()
                    Capsule()
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 100, height: 6)
                    Spacer()
                }
                .frame(width: 180, height: 28)
                .contentShape(Rectangle())
                .onHover { hovering in
                    overlayState.isHovered = hovering
                }
            }
        }
    }

    private var islandBody: some View {
        currentExpandedContent
            .padding(12)
            .frame(width: 500)
            .background(backgroundView)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.black.opacity(0.34), radius: 28, x: 0, y: 12)
            .onHover { hovering in
                overlayState.isHovered = hovering
                if !hovering && !hasAttention && !overlayState.isPinnedExpanded {
                    // 延迟一点再收起，避免闪烁
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if !overlayState.isHovered {
                            overlayState.showOverview(expanded: false)
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private var currentExpandedContent: some View {
        // 直接显示会话列表，权限和问题内嵌到对应会话卡片中
        expandedSessions
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

    private var compactIsland: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题行
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text("AgentPulse")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                headerActions
            }

            // 直接显示会话列表（支持原地展开）
            if prioritizedSessions.isEmpty {
                Text("暂无会话")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(prioritizedSessions.prefix(5)) { session in
                        inlineSessionCard(session, isExpanded: expandedSessionIds.contains(session.id))
                    }
                    if prioritizedSessions.count > 5 {
                        Text("还有 \(prioritizedSessions.count - 5) 个会话...")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
        }
    }

    private var expandedSessions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("活跃会话")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text("点击展开查看详情")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.62))
                }
                Spacer()
                headerActions
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    // 先显示孤立的问题（没有匹配会话的）
                    ForEach(orphanedQuestions) { question in
                        orphanedQuestionCard(question)
                    }

                    // 再显示孤立的权限请求
                    ForEach(orphanedPermissions) { permission in
                        orphanedPermissionCard(permission)
                    }

                    // 最后显示会话列表
                    if prioritizedSessions.isEmpty && orphanedQuestions.isEmpty && orphanedPermissions.isEmpty {
                        Text("暂无运行中的会话")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.62))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 28)
                    } else {
                        ForEach(prioritizedSessions) { session in
                            inlineSessionCard(session, isExpanded: expandedSessionIds.contains(session.id))
                        }
                    }
                }
            }
        }
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
            HStack {
                Image(systemName: permission.icon)
                    .foregroundColor(.orange)
                Text(permission.tool)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
                Spacer()
                Text(String(permission.sessionId.prefix(8)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }

            Text(permission.summary)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.8))

            HStack(spacing: 8) {
                Button(action: { onDeny(permission.id) }) {
                    Text("拒绝")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(action: { onApprove(permission.id) }) {
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
        .padding(12)
        .background(Color.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func inlineSessionCard(_ session: Session, isExpanded: Bool) -> some View {
        let hasSummary = session.currentRequest?.summary != nil
        let isCompleted = hasSummary  // 有 AI 总结就是已完成
        // 获取该会话的待处理权限和问题
        let sessionPermissions = socketServer.pendingPermissions.filter { $0.sessionId == session.id }
        let sessionQuestions = socketServer.pendingQuestions.filter { $0.sessionId == session.id }
        let hasAttention = !sessionPermissions.isEmpty || !sessionQuestions.isEmpty
        // 有待处理事项时自动展开
        let shouldExpand = isExpanded || hasAttention

        // 状态颜色：待处理 > 已完成 > 活跃 > 不活跃
        let dotColor: Color = {
            if hasAttention { return .orange }
            if isCompleted { return .purple }
            if session.isActive { return .green }
            return Color(white: 0.4)
        }()

        return VStack(alignment: .leading, spacing: 0) {
            // 会话头部（整个区域可点击展开/折叠）
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.cwd.isEmpty ? String(session.id.prefix(8)) : (session.cwd as NSString).lastPathComponent)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        sourcePill(session.source)
                        if isCompleted {
                            Text("完成")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.purple)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.2))
                                .cornerRadius(3)
                        }
                    }
                    if !shouldExpand {
                        Text(session.currentRequest?.prompt ?? "等待指令")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(2)
                    }
                }

                Spacer()

                if socketServer.pendingPermissions.contains(where: { $0.sessionId == session.id }) {
                    Text("审批")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.orange)
                }

                Text(relativeTime(session.lastUpdate))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))

                if !session.cwd.isEmpty {
                    Button(action: { onJump(session.id, session.cwd) }) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10))
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                Image(systemName: shouldExpand ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture {
                if expandedSessionIds.contains(session.id) {
                    expandedSessionIds.remove(session.id)
                } else {
                    // 手风琴效果：展开一个，折叠其他
                    expandedSessionIds.removeAll()
                    expandedSessionIds.insert(session.id)
                }
            }

            // 折叠时显示当前进度预览
            if !shouldExpand {
                if let summary = session.currentRequest?.summary {
                    // 显示 AI 总结预览
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                            .foregroundColor(.purple)
                        Text(summary.result)
                            .font(.system(size: 10))
                            .foregroundColor(.purple.opacity(0.8))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                } else if let tool = session.currentRequest?.tools.last {
                    // 显示最新工具调用
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: tool.icon)
                            .font(.system(size: 9))
                            .foregroundColor(toolColor(tool.tool))
                        Text("\(tool.tool) · \(tool.fullDetail)")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }

            // 展开的详情
            if shouldExpand {
                VStack(alignment: .leading, spacing: 10) {
                    // 内嵌的权限申请
                    ForEach(sessionPermissions) { permission in
                        inlinePermissionCard(permission)
                    }

                    // 内嵌的问题
                    ForEach(sessionQuestions) { question in
                        inlineQuestionCard(question)
                    }

                    // 用户请求
                    if let request = session.currentRequest {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "bubble.left.fill")
                                .foregroundColor(.blue)
                                .font(.system(size: 11))
                            Text(request.prompt)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                                .lineLimit(4)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    }

                    // 执行流（可折叠）
                    if let tools = session.currentRequest?.tools, !tools.isEmpty {
                        inlineToolFlow(sessionId: session.id, tools: tools)
                    }

                    // AI 总结
                    if let summary = session.currentRequest?.summary {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10))
                                    .foregroundColor(.purple)
                                Text("AI 总结")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.purple)
                            }
                            if !summary.flow.isEmpty {
                                HStack(alignment: .top, spacing: 4) {
                                    Text("流程")
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.5))
                                        .frame(width: 24, alignment: .leading)
                                    Text(summary.flow)
                                        .font(.system(size: 10))
                                        .foregroundColor(.blue)
                                }
                            }
                            HStack(alignment: .top, spacing: 4) {
                                Text("结果")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.5))
                                    .frame(width: 24, alignment: .leading)
                                Text(summary.result)
                                    .font(.system(size: 10))
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.purple.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(Color.white.opacity(isExpanded ? 0.08 : 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func inlineToolFlow(sessionId: String, tools: [ToolCall]) -> some View {
        let isToolExpanded = expandedToolFlowIds.contains(sessionId)

        return VStack(alignment: .leading, spacing: 8) {
            // 标题行
            HStack {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
                Text("执行流")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Text("\(tools.count) 操作")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
                Image(systemName: isToolExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }

            if isToolExpanded {
                // 展开显示详细列表
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tools.suffix(10)) { tool in
                        HStack(spacing: 6) {
                            Image(systemName: tool.icon)
                                .font(.system(size: 10))
                                .foregroundColor(toolColor(tool.tool))
                                .frame(width: 14)
                            Text(tool.tool)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(toolColor(tool.tool))
                                .frame(width: 50, alignment: .leading)
                            Text(tool.fullDetail.isEmpty ? tool.detail : tool.fullDetail)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                    if tools.count > 10 {
                        Text("... 还有 \(tools.count - 10) 个操作")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            } else {
                // 折叠显示图标流（使用 description 作为描述）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(tools.suffix(6).enumerated()), id: \.element.id) { index, tool in
                            if index > 0 {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 8))
                                    .foregroundColor(.white.opacity(0.3))
                            }
                            VStack(spacing: 3) {
                                Image(systemName: tool.icon)
                                    .font(.system(size: 12))
                                    .foregroundColor(toolColor(tool.tool))
                                    .frame(width: 26, height: 26)
                                    .background(toolColor(tool.tool).opacity(0.15))
                                    .cornerRadius(6)
                                // 显示工具的中文描述
                                Text(toolFlowLabel(tool))
                                    .font(.system(size: 8))
                                    .foregroundColor(.white.opacity(0.6))
                                    .lineLimit(1)
                                    .frame(maxWidth: 80)
                            }
                        }
                        if tools.count > 6 {
                            Text("+\(tools.count - 6)")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if expandedToolFlowIds.contains(sessionId) {
                expandedToolFlowIds.remove(sessionId)
            } else {
                expandedToolFlowIds.insert(sessionId)
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

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
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
                            }
                            if tools.count > 8 {
                                Text("+\(tools.count - 8)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.4))
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
                detailBlock(
                    title: "计划 \(session.tasks.filter { $0.status == .completed }.count)/\(session.tasks.count)",
                    systemImage: "checklist",
                    tint: .orange
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.tasks.suffix(4)) { task in
                            HStack(spacing: 8) {
                                Text(task.statusIcon)
                                    .font(.system(size: 11))
                                    .foregroundColor(task.status == .completed ? .green : .white.opacity(0.8))
                                Text(task.subject)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(task.status == .completed ? 0.55 : 0.84))
                                    .lineLimit(1)
                                    .strikethrough(task.status == .completed)
                            }
                        }
                    }
                }
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
                .fill(session.isActive ? Color.green : Color.gray)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: permission.icon)
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .frame(width: 28, height: 28)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(6)

                VStack(alignment: .leading, spacing: 2) {
                    Text("权限申请")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange)
                    Text(permission.summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(2)
                }
                Spacer()
            }

            if !permission.detail.isEmpty {
                Text(permission.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(6)
            }

            HStack(spacing: 8) {
                Button(action: { onDeny(permission.id) }) {
                    Text("拒绝")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(action: { onApprove(permission.id) }) {
                    Text("批准")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.8))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - 内嵌问题卡片
    private func inlineQuestionCard(_ question: AskRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.blue)
                    .frame(width: 28, height: 28)
                    .background(Color.blue.opacity(0.15))
                    .cornerRadius(6)

                VStack(alignment: .leading, spacing: 2) {
                    Text("等待回答")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.blue)
                    Text(question.firstQuestion)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(3)
                }
                Spacer()
            }

            // 选项按钮
            FlowLayout(spacing: 6) {
                ForEach(question.options, id: \.self) { option in
                    Button(action: { onAnswer(question.id, option) }) {
                        Text(option)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.3))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
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
