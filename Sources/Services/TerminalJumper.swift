import Foundation
import AppKit

/// 终端跳转工具 - 支持 iTerm2 和 Terminal.app
enum TerminalJumper {

    /// 跳转到指定 session 的终端；找不到时自动打开到目标目录并恢复会话
    static func jump(to sessionId: String, cwd: String? = nil, agent: SessionAgent? = nil) {
        NSLog("🚀 TerminalJumper.jump called - sessionId: %@, cwd: %@", sessionId, cwd ?? "nil")

        let session = SessionMonitor.shared.sessions.first(where: { $0.id == sessionId })
        let workDir = cwd ?? session?.cwd ?? ""
        let sessionAgent = agent ?? session?.source ?? .claude
        let resumeCommand = buildResumeCommand(sessionId: sessionId, cwd: workDir, agent: sessionAgent)

        let iTermRunning = NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        })

        DispatchQueue.global(qos: .userInitiated).async {
            NSLog("📱 iTerm2 运行中: %@", iTermRunning ? "是" : "否")

            if iTermRunning {
                openInITerm2(command: resumeCommand)
                return
            }

            openInTerminal(command: resumeCommand)
        }
    }

    /// 跳转到 EnsoAI
    static func jumpToEnsoAI(cwd: String? = nil) {
        NSLog("🚀 TerminalJumper.jumpToEnsoAI called - cwd: %@", cwd ?? "nil")

        DispatchQueue.global(qos: .userInitiated).async {
            _ = openEnsoAIApp(projectPath: cwd)
        }
    }

    /// 跳转到最近活跃的终端
    static func jumpToLatest() {
        // 检查 iTerm2 是否正在运行
        let iTermRunning = NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        })

        DispatchQueue.global(qos: .userInitiated).async {
            if iTermRunning {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            } else {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
        }
    }

    private static func openInITerm2(command: String) {
        let escapedCommand = escapeAppleScript(command)
        let script = """
        tell application "iTerm"
            activate
            if (count of windows) = 0 then
                create window with default profile
            end if
            tell current window
                create tab with default profile
                tell current session
                    write text "\(escapedCommand)"
                end tell
            end tell
        end tell
        """

        _ = runAppleScript(script)
    }

    // MARK: - Terminal.app

    private static func openInTerminal(command: String) {
        let escapedCommand = escapeAppleScript(command)
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapedCommand)"
        end tell
        """

        _ = runAppleScript(script)
    }

    // MARK: - Helper

    private static let ensoAIAppPath = "/Applications/EnsoAI.app"

    @discardableResult
    private static func openEnsoAIApp(projectPath: String?) -> Bool {
        if let projectPath,
           let deepLink = buildEnsoAIURL(projectPath: projectPath),
           NSWorkspace.shared.open(deepLink) {
            return true
        }

        let appURL = URL(fileURLWithPath: ensoAIAppPath)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            NSLog("⚠️ EnsoAI.app not found at path: %@", appURL.path)
            showLaunchFailure(
                title: "无法打开 EnsoAI",
                message: "未找到 /Applications/EnsoAI.app"
            )
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let projectPath, !projectPath.isEmpty {
            configuration.arguments = ["--open-path=\(projectPath)"]
        }

        DispatchQueue.main.async {
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    NSLog("❌ Failed to open EnsoAI.app: %@", error.localizedDescription)
                    showLaunchFailure(
                        title: "无法打开 EnsoAI",
                        message: error.localizedDescription
                    )
                }
            }
        }
        return true
    }

    private static func buildEnsoAIURL(projectPath: String) -> URL? {
        guard !projectPath.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "enso"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "path", value: projectPath)
        ]
        return components.url
    }

    private static func showLaunchFailure(title: String, message: String) {
        DispatchQueue.main.async {
            NSSound.beep()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }

    private static func buildResumeCommand(sessionId: String, cwd: String, agent: SessionAgent) -> String {
        var parts: [String] = []
        if !cwd.isEmpty {
            parts.append("cd \(shellQuote(cwd))")
        }
        switch agent {
        case .codex:
            parts.append("codex resume \(shellQuote(sessionId))")
        case .claude, .unknown:
            parts.append("claude --resume \(shellQuote(sessionId))")
        }
        return parts.joined(separator: " && ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            let result = script.executeAndReturnError(&error)
            if error == nil {
                return result.booleanValue
            }
            NSLog("❌ AppleScript 执行失败: %@", error ?? [:])
        }
        return false
    }
}
