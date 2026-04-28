import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var whitelist = PermissionWhitelist.shared
    @State private var showCleanupConfirm = false
    @State private var showAddRule = false
    @State private var newRuleTool = "Read"
    @State private var newRulePattern = ""

    private let toolOptions = ["*", "Read", "Edit", "Write", "Bash", "Grep", "Glob", "Task", "WebSearch", "WebFetch"]

    var body: some View {
        Form {
            Section("灵动岛") {
                Toggle("启用灵动岛", isOn: $settings.islandEnabled)
                Toggle("审批/提问时自动展开", isOn: $settings.islandAutoExpand)
                Toggle("播放提示音", isOn: $settings.islandPlaySound)
                Toggle("任务完成时通知", isOn: $settings.notifyOnComplete)
                Toggle("非刘海屏也显示", isOn: $settings.islandShowOnNonNotchedDisplays)
            }

            Section("审批模式") {
                Picker("处理位置", selection: $settings.approvalMode) {
                    Text("终端 (推荐)").tag(ApprovalMode.terminal)
                    Text("AgentPulse").tag(ApprovalMode.agentpulse)
                }
                .pickerStyle(.segmented)

                Text(settings.approvalMode == .terminal
                     ? "审批在终端进行，AgentPulse 显示状态"
                     : "审批在 AgentPulse 进行，终端等待响应")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("启用自动批准", isOn: $whitelist.autoApproveEnabled)

                if whitelist.autoApproveEnabled {
                    ForEach(whitelist.rules) { rule in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { rule.enabled },
                                set: { _ in whitelist.toggleRule(rule) }
                            ))
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.tool == "*" ? "所有工具" : rule.tool)
                                    .font(.system(size: 12, weight: .medium))
                                if !rule.pattern.isEmpty {
                                    Text(rule.pattern)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            Button(action: { whitelist.removeRule(rule) }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        .opacity(rule.enabled ? 1 : 0.5)
                    }

                    Button(action: { showAddRule = true }) {
                        Label("添加规则", systemImage: "plus.circle")
                    }

                    // 预设规则
                    Menu {
                        ForEach(PermissionWhitelist.presetRules, id: \.name) { preset in
                            Button(preset.name) {
                                whitelist.applyPreset(preset)
                            }
                        }
                    } label: {
                        Label("应用预设", systemImage: "rectangle.stack")
                    }
                }
            } header: {
                Text("权限白名单")
            } footer: {
                Text("匹配的权限请求将自动批准，无需手动确认")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("会话管理") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("清理非活跃会话")
                        Text("移除所有已结束的会话记录")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("清理") {
                        showCleanupConfirm = true
                    }
                    .buttonStyle(.bordered)
                }
            }

            Section("日志") {
                HStack {
                    Text("日志文件")
                    Spacer()
                    Text("\(LogManager.shared.getLogFiles().count) 个文件")
                        .foregroundColor(.secondary)
                    Button("打开目录") {
                        LogManager.shared.openLogDirectory()
                    }
                    .buttonStyle(.bordered)
                }

                HStack {
                    Text("最近日志")
                    Spacer()
                    Text("\(LogManager.shared.recentLogs.count) 条")
                        .foregroundColor(.secondary)
                    Button("清除") {
                        LogManager.shared.clearLogs()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 600)
        .alert("确认清理", isPresented: $showCleanupConfirm) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                SessionMonitor.shared.clearInactiveSessions()
            }
        } message: {
            Text("将移除所有非活跃的会话记录，此操作不可撤销。")
        }
        .sheet(isPresented: $showAddRule) {
            addRuleSheet
        }
    }

    private var addRuleSheet: some View {
        VStack(spacing: 16) {
            Text("添加白名单规则")
                .font(.headline)

            Picker("工具", selection: $newRuleTool) {
                ForEach(toolOptions, id: \.self) { tool in
                    Text(tool == "*" ? "所有工具" : tool).tag(tool)
                }
            }

            TextField("路径/命令前缀（可选）", text: $newRulePattern)
                .textFieldStyle(.roundedBorder)

            Text("例如：~/Desktop/project 或 git ")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button("取消") {
                    showAddRule = false
                    newRulePattern = ""
                }
                .buttonStyle(.bordered)

                Button("添加") {
                    whitelist.addRule(tool: newRuleTool, pattern: newRulePattern)
                    showAddRule = false
                    newRulePattern = ""
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}
