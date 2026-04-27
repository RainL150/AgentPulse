import SwiftUI

struct SessionRowView: View {
    @ObservedObject var session: Session
    let isExpanded: Bool
    var pendingPermissions: [PermissionRequest] = []
    var pendingQuestions: [AskRequest] = []
    var onToggleExpand: (() -> Void)?
    var onJump: (() -> Void)?
    var onRemove: (() -> Void)?

    var hasPending: Bool {
        !pendingPermissions.isEmpty || !pendingQuestions.isEmpty
    }

    var isCompleted: Bool {
        session.currentRequest?.summary != nil
    }

    var body: some View {
        SessionRowCard(
            sessionId: String(session.id.prefix(8)),
            sourceLabel: session.source.label,
            folderName: session.cwd.isEmpty ? nil : (session.cwd as NSString).lastPathComponent,
            sessionState: session.state,
            isCompleted: isCompleted,
            hasPending: hasPending,
            pendingPermissionCount: pendingPermissions.count,
            completedTaskCount: session.tasks.filter { $0.status == .completed }.count,
            totalTaskCount: session.tasks.count,
            formattedTime: formatTime(session.lastUpdate),
            relativeTime: formatRelativeTime(session.lastUpdate),
            isExpanded: isExpanded,
            hasJump: !session.cwd.isEmpty,
            onSelect: { onToggleExpand?() },
            onJump: { onJump?() },
            onRemove: { onRemove?() }
        )
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func formatRelativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "刚刚"
        } else if interval < 3600 {
            return "\(Int(interval / 60))分钟前"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))小时前"
        } else {
            return "\(Int(interval / 86400))天前"
        }
    }
}

private struct SessionRowCard: View {
    let sessionId: String
    let sourceLabel: String
    let folderName: String?
    let sessionState: SessionState
    let isCompleted: Bool
    let hasPending: Bool
    let pendingPermissionCount: Int
    let completedTaskCount: Int
    let totalTaskCount: Int
    let formattedTime: String
    let relativeTime: String
    let isExpanded: Bool
    let hasJump: Bool
    let onSelect: () -> Void
    let onJump: () -> Void
    let onRemove: () -> Void

    var body: some View {
        rowLayout
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(rowHighlightColor)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .contextMenu {
                Button(action: onJump) {
                    Label("跳转终端", systemImage: "terminal")
                }
                .disabled(!hasJump)

                Divider()

                Button(role: .destructive, action: onRemove) {
                    Label("移除会话", systemImage: "trash")
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(cardFillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(cardStrokeColor, lineWidth: 1)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .preferredColorScheme(.dark)
    }

    private var rowLayout: some View {
        HStack(spacing: 10) {
            StatusDotView(sessionState: sessionState, isCompleted: isCompleted, hasPending: hasPending)
            TitleMetaView(
                sessionId: sessionId,
                sourceLabel: sourceLabel,
                folderName: folderName,
                sessionState: sessionState,
                pendingPermissionCount: pendingPermissionCount
            )
            Spacer()
            taskArea
            TimeTextView(formattedTime: formattedTime, relativeTime: relativeTime)
            jumpArea
            ChevronView(isExpanded: isExpanded)
        }
    }

    @ViewBuilder
    private var taskArea: some View {
        if totalTaskCount > 0 {
            TaskPillView(completedTaskCount: completedTaskCount, totalTaskCount: totalTaskCount)
        }
    }

    @ViewBuilder
    private var jumpArea: some View {
        if hasJump {
            JumpIconButton(onJump: onJump)
        }
    }

    private var rowHighlightColor: Color {
        if hasPending { return Color.orange.opacity(0.1) }
        switch sessionState {
        case .running: return Color.green.opacity(0.05)
        case .idle: return Color.yellow.opacity(0.03)
        case .stopped, .expired: return .clear
        }
    }

    private var cardFillColor: Color {
        isExpanded ? Color.white.opacity(0.08) : Color.white.opacity(0.04)
    }

    private var cardStrokeColor: Color {
        isExpanded ? Color.white.opacity(0.16) : Color.white.opacity(0.06)
    }
}

private struct StatusDotView: View {
    let sessionState: SessionState
    let isCompleted: Bool
    let hasPending: Bool

    var dotColor: Color {
        if hasPending {
            return .orange
        }
        if isCompleted {
            return .purple
        }
        switch sessionState {
        case .running: return .green
        case .idle: return .yellow
        case .stopped: return Color(white: 0.5)
        case .expired: return Color(white: 0.3)
        }
    }

    var dotIcon: String? {
        if hasPending || isCompleted { return nil }
        switch sessionState {
        case .running: return nil
        case .idle: return "pause.fill"
        case .stopped: return "stop.fill"
        case .expired: return "xmark"
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            if hasPending {
                Circle()
                    .stroke(Color.orange, lineWidth: 2)
                    .frame(width: 14, height: 14)
                    .opacity(0.5)
            }

            if let icon = dotIcon {
                Image(systemName: icon)
                    .font(.system(size: 5, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }
}

private struct TitleMetaView: View {
    let sessionId: String
    let sourceLabel: String
    let folderName: String?
    let sessionState: SessionState
    let pendingPermissionCount: Int

    var stateColor: Color {
        switch sessionState {
        case .running: return .green
        case .idle: return .yellow
        case .stopped: return Color(white: 0.5)
        case .expired: return Color(white: 0.4)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(sessionId)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)

                Text(sourceLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(sourceLabel == "codex" ? Color(red: 0.54, green: 0.86, blue: 1.0) : Color(red: 1.0, green: 0.78, blue: 0.52))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)

                // 非运行状态显示状态标签
                if sessionState != .running {
                    Text(sessionState.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(stateColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(stateColor.opacity(0.15))
                        .cornerRadius(4)
                }

                if pendingPermissionCount > 0 {
                    Text("\(pendingPermissionCount) 待审批")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange)
                        .cornerRadius(4)
                }
            }

            if let folderName, !folderName.isEmpty {
                Text(folderName)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }
}

private struct TaskPillView: View {
    let completedTaskCount: Int
    let totalTaskCount: Int

    var body: some View {
        Text("\(completedTaskCount)/\(totalTaskCount)")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.62))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.08))
            .cornerRadius(4)
    }
}

private struct TimeTextView: View {
    let formattedTime: String
    var relativeTime: String = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(formattedTime)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
            if !relativeTime.isEmpty && relativeTime != "刚刚" {
                Text(relativeTime)
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
    }
}

private struct JumpIconButton: View {
    let onJump: () -> Void

    var body: some View {
        Button(action: onJump) {
            Image(systemName: "terminal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("跳转到当前会话终端")
    }
}

private struct ChevronView: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.48))
    }
}

// MARK: - 内联的权限请求卡片

struct InlinePermissionCard: View {
    let permission: PermissionRequest
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题行
            HStack {
                Image(systemName: permission.icon)
                    .foregroundColor(.orange)
                    .font(.system(size: 12))
                Text(permission.tool)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
                Spacer()
                Text("需要审批")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }

            // 摘要
            Text(permission.summary)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)

            // 详情（直接显示，不折叠）
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

            // 使用原生 SwiftUI 按钮
            HStack(spacing: 8) {
                Button(action: {
                    NSLog("🔴 拒绝!")
                    onDeny()
                }) {
                    Text("拒绝")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(action: {
                    NSLog("🟢 批准!")
                    onApprove()
                }) {
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
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - 内联的问题卡片

struct InlineQuestionCard: View {
    let question: AskRequest
    let onAnswer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: 12))
                Text("需要回答")
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
            }

                Text(question.firstQuestion)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)

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
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
    }
}

struct SessionDetailView: View {
    @ObservedObject var session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 当前请求
            if let request = session.currentRequest {
                RequestBlockView(request: request)
            }

            // 任务计划
            if !session.tasks.isEmpty {
                TaskPlanView(tasks: session.tasks)
            }
        }
    }
}

struct RequestBlockView: View {
    @ObservedObject var request: UserRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 用户请求
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "bubble.left.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: 11))
                Text(request.prompt)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(8)

            // 工具执行流
            if !request.tools.isEmpty {
                ToolFlowView(tools: request.tools)
            }

            // AI 总结
            if let summary = request.summary {
                SummaryView(summary: summary)
            }
        }
    }
}

struct ToolFlowView: View {
    let tools: [ToolCall]
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "arrow.right.circle")
                    .foregroundColor(.secondary)
                Text("执行流")
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(tools.count) 操作")
                    .foregroundColor(.secondary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundColor(.secondary)
                    .font(.system(size: 9))
            }
            .font(.system(size: 10, weight: .medium))
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tools.suffix(20)) { tool in
                        ToolDetailRow(tool: tool)
                    }
                    if tools.count > 20 {
                        Text("... 还有 \(tools.count - 20) 个操作")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                // 图标流展示：icon → icon → icon
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(tools.suffix(8).enumerated()), id: \.element.id) { index, tool in
                            if index > 0 {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                            VStack(spacing: 2) {
                                Image(systemName: tool.icon)
                                    .font(.system(size: 14))
                                    .foregroundColor(toolColor(tool.tool))
                                    .frame(width: 24, height: 24)
                                    .background(toolColor(tool.tool).opacity(0.1))
                                    .cornerRadius(4)
                                Text(toolShortName(tool))
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if tools.count > 8 {
                            Text("...")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    private func toolColor(_ tool: String) -> Color {
        switch tool {
        case "Read": return .blue
        case "Edit", "Write": return .orange
        case "Bash": return .green
        case "Grep", "Glob": return .purple
        case "WebSearch", "WebFetch": return .cyan
        case "TaskCreate", "TaskUpdate": return .pink
        default: return .secondary
        }
    }

    private func toolShortName(_ tool: ToolCall) -> String {
        // 优先显示有意义的短标签
        let detail = tool.detail
        if !detail.isEmpty {
            // 取前10个字符作为短名称
            return String(detail.prefix(10))
        }
        // 回退到工具名
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
        case "TaskCreate": return "task+"
        case "TaskUpdate": return "task✓"
        default: return tool.tool.lowercased()
        }
    }
}

struct ToolDetailRow: View {
    let tool: ToolCall

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tool.icon)
                .font(.system(size: 10))
                .foregroundColor(toolColor)
                .frame(width: 14)

            Text(tool.tool)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(toolColor)
                .frame(width: 55, alignment: .leading)

            Text(tool.fullDetail)
                .font(.system(size: 10))
                .foregroundColor(.primary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(formatTime(tool.time))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    var toolColor: Color {
        switch tool.tool {
        case "Read": return .blue
        case "Edit", "Write": return .orange
        case "Bash": return .green
        case "Grep", "Glob": return .purple
        case "WebSearch", "WebFetch": return .cyan
        case "TaskCreate", "TaskUpdate": return .pink
        default: return .secondary
        }
    }

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct TaskPlanView: View {
    let tasks: [Task]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checklist")
                    .foregroundColor(.orange)
                Text("计划")
                    .foregroundColor(.secondary)
                Spacer()
                let completed = tasks.filter { $0.status == .completed }.count
                Text("\(completed)/\(tasks.count) 完成")
                    .foregroundColor(.secondary)
            }
            .font(.system(size: 10, weight: .medium))

            ForEach(tasks.prefix(5)) { task in
                HStack(spacing: 6) {
                    Text(task.statusIcon)
                        .font(.system(size: 10))
                        .foregroundColor(statusColor(task.status))
                    Text(task.subject)
                        .font(.system(size: 11))
                        .foregroundColor(task.status == .completed ? .secondary : .primary)
                        .strikethrough(task.status == .completed)
                        .lineLimit(1)
                }
            }

            if tasks.count > 5 {
                Text("还有 \(tasks.count - 5) 个任务...")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(6)
    }

    private func statusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .pending: return .gray
        case .inProgress: return .blue
        case .completed: return .green
        }
    }
}

struct SummaryView: View {
    let summary: Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.purple)
                Text("AI 总结")
                    .foregroundColor(.purple)
                Spacer()
            }
            .font(.system(size: 10, weight: .medium))

            if !summary.flow.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Text("流程")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 28, alignment: .leading)
                    Text(summary.flow)
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                    Spacer()
                }
            }

            HStack(alignment: .top, spacing: 4) {
                Text("结果")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 28, alignment: .leading)
                Text(summary.result)
                    .font(.system(size: 11))
                    .foregroundColor(.green)
                Spacer()
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.08))
        .cornerRadius(6)
    }
}
