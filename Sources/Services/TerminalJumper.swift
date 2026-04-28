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
        let searchTerms = buildSearchTerms(sessionId: sessionId, cwd: workDir)

        let iTermRunning = NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        })

        // 在后台线程执行 AppleScript，避免阻塞 UI
        DispatchQueue.global(qos: .userInitiated).async {
            NSLog("🔍 搜索词: %@", searchTerms.joined(separator: ", "))
            NSLog("📱 iTerm2 运行中: %@", iTermRunning ? "是" : "否")

            if iTermRunning {
                if jumpITerm2(searchTerms: searchTerms) {
                    return
                }
                openInITerm2(command: resumeCommand)
                return
            }

            NSLog("📺 尝试 Terminal.app")
            if jumpTerminal(searchTerms: searchTerms) {
                return
            }
            openInTerminal(command: resumeCommand)
        }
    }

    /// 跳转到 EnsoAI
    static func jumpToEnsoAI(cwd: String? = nil) {
        NSLog("🚀 TerminalJumper.jumpToEnsoAI called - cwd: %@", cwd ?? "nil")

        let workDir = cwd ?? ""
        var command = ""
        if !workDir.isEmpty {
            command = "cd \(shellQuote(workDir)) && ensoai"
        } else {
            command = "ensoai"
        }

        let iTermRunning = NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        })

        DispatchQueue.global(qos: .userInitiated).async {
            if iTermRunning {
                openInITerm2(command: command)
            } else {
                openInTerminal(command: command)
            }
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

    // MARK: - iTerm2

    private static func jumpITerm2(searchTerms: [String]) -> Bool {
        let conditions = searchTerms.map { term in
            let escaped = escapeAppleScript(term)
            return #"sessionText contains "\#(escaped)""#
        }.joined(separator: " or ")

        let script = """
        tell application "iTerm"
            activate
            set found to false
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set sessionText to (name of s as text) & " " & (tty of s as text)
                        if \(conditions) then
                            select t
                            select s
                            set found to true
                            exit repeat
                        end if
                    end repeat
                    if found then exit repeat
                end repeat
                if found then exit repeat
            end repeat
            return found
        end tell
        """

        return runAppleScript(script)
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

    private static func jumpTerminal(searchTerms: [String]) -> Bool {
        let listScript = """
        tell application "Terminal"
            set names to {}
            repeat with w in windows
                set end of names to name of w
            end repeat
            return names
        end tell
        """
        if let script = NSAppleScript(source: listScript) {
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            NSLog("📋 Terminal 窗口列表: %@", result.stringValue ?? "无")
        }

        let conditions = searchTerms.map { term in
            let escaped = escapeAppleScript(term)
            return #"tabText contains "\#(escaped)""#
        }.joined(separator: " or ")

        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    set tabText to (custom title of t as text) & " " & (name of t as text) & " " & (tty of t as text)
                    if \(conditions) then
                        set selected of t to true
                        set frontmost of w to true
                        return true
                    end if
                end repeat
            end repeat
            return false
        end tell
        """

        let found = runAppleScript(script)
        NSLog("🎯 Terminal 跳转结果: %@", found ? "找到" : "未找到")
        return found
    }

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

    private static func buildSearchTerms(sessionId: String, cwd: String) -> [String] {
        var terms: [String] = []
        if !cwd.isEmpty {
            terms.append(cwd)
            let dirName = (cwd as NSString).lastPathComponent
            if !dirName.isEmpty {
                terms.append(dirName)
            }
        }
        terms.append(sessionId)
        terms.append(String(sessionId.prefix(8)))
        return Array(NSOrderedSet(array: terms)) as? [String] ?? terms
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
