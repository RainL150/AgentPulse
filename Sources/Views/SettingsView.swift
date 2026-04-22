import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var showCleanupConfirm = false

    var body: some View {
        Form {
            Section("灵动岛") {
                Toggle("启用灵动岛", isOn: $settings.islandEnabled)
                Toggle("审批/提问时自动展开", isOn: $settings.islandAutoExpand)
                Toggle("播放提示音", isOn: $settings.islandPlaySound)
                Toggle("非刘海屏也显示", isOn: $settings.islandShowOnNonNotchedDisplays)
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
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 280)
        .alert("确认清理", isPresented: $showCleanupConfirm) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                SessionMonitor.shared.clearInactiveSessions()
            }
        } message: {
            Text("将移除所有非活跃的会话记录，此操作不可撤销。")
        }
    }
}
