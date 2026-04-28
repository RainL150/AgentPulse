import Foundation
import Combine

/// Token使用统计
struct TokenUsage {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0

    var totalInput: Int {
        inputTokens + cacheCreationTokens + cacheReadTokens
    }

    var total: Int {
        totalInput + outputTokens
    }

    mutating func add(_ other: TokenUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheCreationTokens += other.cacheCreationTokens
        cacheReadTokens += other.cacheReadTokens
    }

    /// 格式化显示
    var formatted: String {
        formatTokenCount(total)
    }

    var inputFormatted: String {
        formatTokenCount(totalInput)
    }

    var outputFormatted: String {
        formatTokenCount(outputTokens)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }
}

/// Token使用服务 - 从Claude Code的会话日志中读取token消耗数据
class TokenUsageService: ObservableObject {
    static let shared = TokenUsageService()

    @Published var sessionUsage: [String: TokenUsage] = [:]
    @Published var totalUsage = TokenUsage()

    private let projectsDir: String
    private var watcher: DispatchSourceFileSystemObject?
    private var lastReadPositions: [String: UInt64] = [:]

    private init() {
        // Claude Code 会话日志目录
        projectsDir = NSHomeDirectory() + "/.claude/projects"
    }

    func start() {
        // 初始扫描
        scanAllSessions()

        // 监听变化（简化版，定期扫描）
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.scanAllSessions()
        }
    }

    func scanAllSessions() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.performScan()
        }
    }

    private func performScan() {
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else {
            return
        }

        var newSessionUsage: [String: TokenUsage] = [:]
        var newTotalUsage = TokenUsage()

        for dir in dirs {
            let dirPath = "\(projectsDir)/\(dir)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }

            // 扫描该项目目录下的所有 JSONL 文件
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else {
                continue
            }

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = "\(dirPath)/\(file)"
                let sessionId = file.replacingOccurrences(of: ".jsonl", with: "")

                let usage = parseSessionFile(path: filePath, sessionId: sessionId)
                if usage.total > 0 {
                    newSessionUsage[sessionId] = usage
                    newTotalUsage.add(usage)
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.sessionUsage = newSessionUsage
            self?.totalUsage = newTotalUsage
        }
    }

    private func parseSessionFile(path: String, sessionId: String) -> TokenUsage {
        var usage = TokenUsage()

        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return usage
        }

        let lines = content.components(separatedBy: "\n")

        for line in lines where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let usageData = message["usage"] as? [String: Any] else {
                continue
            }

            // 解析 token 数据
            if let input = usageData["input_tokens"] as? Int {
                usage.inputTokens += input
            }
            if let output = usageData["output_tokens"] as? Int {
                usage.outputTokens += output
            }
            if let cacheCreation = usageData["cache_creation_input_tokens"] as? Int {
                usage.cacheCreationTokens += cacheCreation
            }
            if let cacheRead = usageData["cache_read_input_tokens"] as? Int {
                usage.cacheReadTokens += cacheRead
            }
        }

        return usage
    }

    /// 获取指定会话的token使用量
    func usage(for sessionId: String) -> TokenUsage {
        sessionUsage[sessionId] ?? TokenUsage()
    }
}
