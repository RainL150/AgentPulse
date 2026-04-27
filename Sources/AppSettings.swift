import Foundation

enum ApprovalMode: String {
    case agentpulse = "agentpulse"  // 只在 AgentPulse 处理审批
    case terminal = "terminal"       // 在终端处理，AgentPulse 只显示状态
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var islandEnabled: Bool {
        didSet { defaults.set(islandEnabled, forKey: Keys.islandEnabled) }
    }

    @Published var islandAutoExpand: Bool {
        didSet { defaults.set(islandAutoExpand, forKey: Keys.islandAutoExpand) }
    }

    @Published var islandPlaySound: Bool {
        didSet { defaults.set(islandPlaySound, forKey: Keys.islandPlaySound) }
    }

    @Published var islandShowOnNonNotchedDisplays: Bool {
        didSet { defaults.set(islandShowOnNonNotchedDisplays, forKey: Keys.islandShowOnNonNotchedDisplays) }
    }

    @Published var approvalMode: ApprovalMode {
        didSet {
            defaults.set(approvalMode.rawValue, forKey: Keys.approvalMode)
            updateHookEnvironment()
        }
    }

    @Published var notifyOnComplete: Bool {
        didSet { defaults.set(notifyOnComplete, forKey: Keys.notifyOnComplete) }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.islandEnabled = defaults.object(forKey: Keys.islandEnabled) as? Bool ?? true
        self.islandAutoExpand = defaults.object(forKey: Keys.islandAutoExpand) as? Bool ?? true
        self.islandPlaySound = defaults.object(forKey: Keys.islandPlaySound) as? Bool ?? true
        self.islandShowOnNonNotchedDisplays = defaults.object(forKey: Keys.islandShowOnNonNotchedDisplays) as? Bool ?? true
        self.notifyOnComplete = defaults.object(forKey: Keys.notifyOnComplete) as? Bool ?? true

        if let modeStr = defaults.string(forKey: Keys.approvalMode),
           let mode = ApprovalMode(rawValue: modeStr) {
            self.approvalMode = mode
        } else {
            self.approvalMode = .terminal  // 默认在终端处理
        }
    }

    /// 更新 hook 环境变量配置文件
    private func updateHookEnvironment() {
        let envPath = NSHomeDirectory() + "/.claude/hooks/.env"
        let content = "AGENTPULSE_BLOCKING=\(approvalMode == .agentpulse ? "1" : "0")\n"
        try? content.write(toFile: envPath, atomically: true, encoding: .utf8)
    }

    private enum Keys {
        static let islandEnabled = "settings.islandEnabled"
        static let islandAutoExpand = "settings.islandAutoExpand"
        static let islandPlaySound = "settings.islandPlaySound"
        static let islandShowOnNonNotchedDisplays = "settings.islandShowOnNonNotchedDisplays"
        static let approvalMode = "settings.approvalMode"
        static let notifyOnComplete = "settings.notifyOnComplete"
    }
}
