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

/// Token使用服务 - 只跟踪最近活跃的会话日志，避免启动时全量扫描拖死 UI
class TokenUsageService: ObservableObject {
    static let shared = TokenUsageService()

    @Published var sessionUsage: [String: TokenUsage] = [:]
    @Published var totalUsage = TokenUsage()

    private let projectsDir: String
    private var scanTimer: Timer?
    private var isScanning = false
    private var lastReadPositions: [String: UInt64] = [:]
    private var cachedUsageByFile: [String: TokenUsage] = [:]
    private let maxTrackedFiles = 120
    private let recentActivityWindow: TimeInterval = 14 * 24 * 60 * 60

    private init() {
        projectsDir = NSHomeDirectory() + "/.claude/projects"
    }

    func start() {
        guard scanTimer == nil else { return }

        // 应用先起来，再在后台做首轮统计。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.scanAllSessions()
        }

        scanTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.scanAllSessions()
        }
    }

    func scanAllSessions() {
        guard !isScanning else { return }
        isScanning = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.performScan()
        }
    }

    private func performScan() {
        defer { isScanning = false }

        let files = recentSessionFiles()
        guard !files.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.sessionUsage = [:]
                self?.totalUsage = TokenUsage()
            }
            return
        }

        var newSessionUsage: [String: TokenUsage] = [:]
        var newTotalUsage = TokenUsage()

        for filePath in files {
            let sessionId = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
            let usage = parseSessionFile(path: filePath)
            if usage.total > 0 {
                newSessionUsage[sessionId] = usage
                newTotalUsage.add(usage)
            }
        }

        let tracked = Set(files)
        cachedUsageByFile = cachedUsageByFile.filter { tracked.contains($0.key) }
        lastReadPositions = lastReadPositions.filter { tracked.contains($0.key) }

        DispatchQueue.main.async { [weak self] in
            self?.sessionUsage = newSessionUsage
            self?.totalUsage = newTotalUsage
        }
    }

    private func recentSessionFiles() -> [String] {
        let rootURL = URL(fileURLWithPath: projectsDir)
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let now = Date()
        var candidates: [(path: String, modifiedAt: Date)] = []

        for dirURL in projectDirs {
            guard let fileURLs = try? FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for fileURL in fileURLs where fileURL.pathExtension == "jsonl" {
                let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                let modifiedAt = values?.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(modifiedAt) <= recentActivityWindow {
                    candidates.append((fileURL.path, modifiedAt))
                }
            }
        }

        if candidates.isEmpty {
            for dirURL in projectDirs.prefix(20) {
                guard let fileURLs = try? FileManager.default.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }

                for fileURL in fileURLs where fileURL.pathExtension == "jsonl" {
                    let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                    candidates.append((fileURL.path, values?.contentModificationDate ?? .distantPast))
                }
            }
        }

        return candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxTrackedFiles)
            .map(\.path)
    }

    private func parseSessionFile(path: String) -> TokenUsage {
        let previousUsage = cachedUsageByFile[path] ?? TokenUsage()
        let previousOffset = lastReadPositions[path] ?? 0

        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let fileSizeNumber = attributes[.size] as? NSNumber
        else {
            return previousUsage
        }

        let fileSize = fileSizeNumber.uint64Value
        if previousOffset > fileSize {
            lastReadPositions[path] = 0
            cachedUsageByFile[path] = TokenUsage()
            return parseSessionFile(path: path)
        }

        guard let handle = FileHandle(forReadingAtPath: path) else {
            return previousUsage
        }

        defer { try? handle.close() }

        if previousOffset > 0 {
            try? handle.seek(toOffset: previousOffset)
        }

        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else {
            return previousUsage
        }

        guard let content = String(data: data, encoding: .utf8) else {
            return previousUsage
        }

        var usage = previousUsage
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8) else { continue }
            accumulateUsage(from: lineData, into: &usage)
        }

        lastReadPositions[path] = fileSize
        cachedUsageByFile[path] = usage
        return usage
    }

    private func accumulateUsage(from lineData: Data, into usage: inout TokenUsage) {
        guard
            let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let usageData = message["usage"] as? [String: Any]
        else {
            return
        }

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

    /// 获取指定会话的token使用量
    func usage(for sessionId: String) -> TokenUsage {
        sessionUsage[sessionId] ?? TokenUsage()
    }
}
