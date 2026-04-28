import Foundation

// MARK: - WhitelistRule

struct WhitelistRule: Codable, Identifiable, Equatable {
    let id: UUID
    var tool: String           // 工具名称，如 "Bash", "Read", "*" 表示所有
    var pattern: String        // 匹配模式（路径前缀或命令前缀）
    var enabled: Bool

    init(tool: String, pattern: String, enabled: Bool = true) {
        self.id = UUID()
        self.tool = tool
        self.pattern = pattern
        self.enabled = enabled
    }

    func matches(_ request: PermissionRequest) -> Bool {
        guard enabled else { return false }

        // 工具匹配
        if tool != "*" && tool != request.tool { return false }

        // 空模式匹配所有
        if pattern.isEmpty { return true }

        // 路径匹配（Read/Edit/Write）
        if let path = request.input["file_path"] as? String {
            return path.hasPrefix(pattern)
        }

        // 命令匹配（Bash）
        if let cmd = request.input["command"] as? String ?? request.input["cmd"] as? String {
            return cmd.hasPrefix(pattern)
        }

        // 搜索模式匹配（Grep/Glob）
        if let searchPattern = request.input["pattern"] as? String {
            return searchPattern.hasPrefix(pattern)
        }

        return false
    }
}

// MARK: - PermissionWhitelist

class PermissionWhitelist: ObservableObject {
    static let shared = PermissionWhitelist()

    @Published var rules: [WhitelistRule] = []
    @Published var autoApproveEnabled: Bool = false

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("AgentPulse")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        fileURL = appDir.appendingPathComponent("whitelist.json")
        load()
    }

    // MARK: - Check

    func shouldAutoApprove(_ request: PermissionRequest) -> Bool {
        guard autoApproveEnabled else { return false }
        return rules.contains { $0.matches(request) }
    }

    // MARK: - Manage Rules

    func addRule(tool: String, pattern: String) {
        let rule = WhitelistRule(tool: tool, pattern: pattern)
        rules.append(rule)
        save()
    }

    func removeRule(_ rule: WhitelistRule) {
        rules.removeAll { $0.id == rule.id }
        save()
    }

    func toggleRule(_ rule: WhitelistRule) {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx].enabled.toggle()
            save()
        }
    }

    func updateRule(_ rule: WhitelistRule, tool: String, pattern: String) {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx].tool = tool
            rules[idx].pattern = pattern
            save()
        }
    }

    // MARK: - Persistence

    private func save() {
        let data = SaveData(rules: rules, autoApproveEnabled: autoApproveEnabled)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(SaveData.self, from: data) else {
            // 默认规则
            rules = [
                WhitelistRule(tool: "Read", pattern: "", enabled: false),
                WhitelistRule(tool: "Grep", pattern: "", enabled: false),
                WhitelistRule(tool: "Glob", pattern: "", enabled: false),
            ]
            return
        }
        rules = decoded.rules
        autoApproveEnabled = decoded.autoApproveEnabled
    }

    private struct SaveData: Codable {
        let rules: [WhitelistRule]
        let autoApproveEnabled: Bool
    }
}

// MARK: - Preset Rules

extension PermissionWhitelist {
    static let presetRules: [(name: String, rules: [WhitelistRule])] = [
        ("只读模式", [
            WhitelistRule(tool: "Read", pattern: ""),
            WhitelistRule(tool: "Grep", pattern: ""),
            WhitelistRule(tool: "Glob", pattern: ""),
        ]),
        ("项目目录", [
            WhitelistRule(tool: "Read", pattern: "~/Desktop/project"),
            WhitelistRule(tool: "Edit", pattern: "~/Desktop/project"),
            WhitelistRule(tool: "Write", pattern: "~/Desktop/project"),
        ]),
        ("Git 操作", [
            WhitelistRule(tool: "Bash", pattern: "git "),
        ]),
    ]

    func applyPreset(_ preset: (name: String, rules: [WhitelistRule])) {
        for rule in preset.rules {
            if !rules.contains(where: { $0.tool == rule.tool && $0.pattern == rule.pattern }) {
                rules.append(rule)
            }
        }
        save()
    }
}
