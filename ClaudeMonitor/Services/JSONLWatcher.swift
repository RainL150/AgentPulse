import Foundation

/// 监听 JSONL 日志文件变化，实时解析新记录
class JSONLWatcher {
    private let path: String
    private let onRecord: (LogRecord) -> Void
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var lastOffset: UInt64 = 0

    init(path: String, onRecord: @escaping (LogRecord) -> Void) {
        self.path = path
        self.onRecord = onRecord
    }

    func start() {
        // 确保目录存在
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // 如果文件不存在则创建
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        // 读取现有内容
        readExisting()

        // 设置文件监听
        setupWatcher()
    }

    func stop() {
        source?.cancel()
        source = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func readExisting() {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        // 只处理最近的 100 条记录
        for line in lines.suffix(100) {
            parseAndEmit(String(line))
        }

        lastOffset = UInt64(data.count)
    }

    private func setupWatcher() {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            print("Failed to open file: \(path)")
            return
        }

        fileHandle = handle
        handle.seek(toFileOffset: lastOffset)

        let fd = handle.fileDescriptor
        let queue = DispatchQueue(label: "jsonl.watcher", qos: .utility)

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )

        source?.setEventHandler { [weak self] in
            self?.readNewContent()
        }

        source?.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
        }

        source?.resume()
    }

    private func readNewContent() {
        guard let handle = fileHandle else { return }

        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty,
              let content = String(data: data, encoding: .utf8) else { return }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            parseAndEmit(String(line))
        }
    }

    private func parseAndEmit(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = LogRecord(json: json) else { return }

        onRecord(record)
    }
}
