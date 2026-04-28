import Foundation
import AppKit

// MARK: - LogLevel

enum LogLevel: String, Codable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    var emoji: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }
}

// MARK: - LogEntry

struct LogEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String

    init(level: LogLevel, category: String, message: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.level = level
        self.category = category
        self.message = message
    }

    var formatted: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return "[\(dateFormatter.string(from: timestamp))] \(level.emoji) [\(category)] \(message)"
    }
}

// MARK: - LogManager

class LogManager: ObservableObject {
    static let shared = LogManager()

    @Published var recentLogs: [LogEntry] = []

    private let logDir: URL
    private var currentLogFile: URL
    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "log.manager", qos: .utility)
    private let maxLogFileSize: UInt64 = 5 * 1024 * 1024  // 5MB
    private let maxLogFiles = 5
    private let maxRecentLogs = 200

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        logDir = appSupport.appendingPathComponent("AgentPulse/logs")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        currentLogFile = logDir.appendingPathComponent("agentpulse.log")
        openLogFile()
        rotateIfNeeded()
    }

    deinit {
        fileHandle?.closeFile()
    }

    // MARK: - Public API

    func log(_ level: LogLevel, category: String, _ message: String) {
        let entry = LogEntry(level: level, category: category, message: message)

        queue.async { [weak self] in
            self?.writeToFile(entry)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recentLogs.append(entry)
            if self.recentLogs.count > self.maxRecentLogs {
                self.recentLogs.removeFirst(self.recentLogs.count - self.maxRecentLogs)
            }
        }

        // 同时输出到 NSLog
        NSLog("\(entry.formatted)")
    }

    func debug(_ category: String, _ message: String) {
        log(.debug, category: category, message)
    }

    func info(_ category: String, _ message: String) {
        log(.info, category: category, message)
    }

    func warning(_ category: String, _ message: String) {
        log(.warning, category: category, message)
    }

    func error(_ category: String, _ message: String) {
        log(.error, category: category, message)
    }

    // MARK: - Log Files

    func getLogFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.creationDateKey]))
            ?? []
        return files
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func readLogFile(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func openLogDirectory() {
        NSWorkspace.shared.open(logDir)
    }

    func clearLogs() {
        for file in getLogFiles() {
            try? FileManager.default.removeItem(at: file)
        }
        recentLogs.removeAll()
        openLogFile()
    }

    // MARK: - Private

    private func openLogFile() {
        if !FileManager.default.fileExists(atPath: currentLogFile.path) {
            FileManager.default.createFile(atPath: currentLogFile.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: currentLogFile)
        fileHandle?.seekToEndOfFile()
    }

    private func writeToFile(_ entry: LogEntry) {
        guard let handle = fileHandle else { return }
        let line = entry.formatted + "\n"
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }

        // 检查是否需要轮转
        if let size = try? currentLogFile.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           UInt64(size) > maxLogFileSize {
            rotateLogFiles()
        }
    }

    private func rotateIfNeeded() {
        guard let size = try? currentLogFile.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              UInt64(size) > maxLogFileSize else { return }
        rotateLogFiles()
    }

    private func rotateLogFiles() {
        fileHandle?.closeFile()
        fileHandle = nil

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let newName = "agentpulse-\(dateFormatter.string(from: Date())).log"
        let newPath = logDir.appendingPathComponent(newName)

        try? FileManager.default.moveItem(at: currentLogFile, to: newPath)

        // 删除旧日志文件
        let files = getLogFiles()
        if files.count > maxLogFiles {
            for file in files.suffix(from: maxLogFiles) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        openLogFile()
    }
}

// MARK: - Global Log Functions

func logDebug(_ category: String, _ message: String) {
    LogManager.shared.debug(category, message)
}

func logInfo(_ category: String, _ message: String) {
    LogManager.shared.info(category, message)
}

func logWarning(_ category: String, _ message: String) {
    LogManager.shared.warning(category, message)
}

func logError(_ category: String, _ message: String) {
    LogManager.shared.error(category, message)
}
