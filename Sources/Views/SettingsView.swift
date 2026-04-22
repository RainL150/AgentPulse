import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("灵动岛") {
                Toggle("启用灵动岛", isOn: $settings.islandEnabled)
                Toggle("审批/提问时自动展开", isOn: $settings.islandAutoExpand)
                Toggle("播放提示音", isOn: $settings.islandPlaySound)
                Toggle("非刘海屏也显示", isOn: $settings.islandShowOnNonNotchedDisplays)
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 200)
    }
}
