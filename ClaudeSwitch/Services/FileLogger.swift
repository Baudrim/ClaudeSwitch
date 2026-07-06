import Foundation

/// Lightweight file logger, mirroring CCSwitcher's approach so debugging the account
/// switch flow doesn't depend on Console.app filtering.
/// Usage: `let log = FileLog("Category"); log.info("message")`
/// Read logs: `tail -f ~/Library/Logs/ClaudeSwitch-app.log`
struct FileLog: Sendable {
    private static let shared = FileLogWriter()
    private let category: String

    init(_ category: String) {
        self.category = category
    }

    func info(_ message: String) { FileLog.shared.write("INFO", category, message) }
    func warning(_ message: String) { FileLog.shared.write("WARN", category, message) }
    func error(_ message: String) { FileLog.shared.write("ERROR", category, message) }
    func debug(_ message: String) { FileLog.shared.write("DEBUG", category, message) }
}

private final class FileLogWriter: @unchecked Sendable {
    private let basePath: String
    private var fileHandle: FileHandle?
    private var bytesWritten: UInt64 = 0
    private let queue = DispatchQueue(label: "com.claudeswitch.filelog")
    private let dateFormatter: ISO8601DateFormatter

    private static let maxFileBytes: UInt64 = 5 * 1024 * 1024  // 5 MB
    private static let keepRotated = 2  // .1 and .2 → ~15MB total cap

    init() {
        let logsDir = NSHomeDirectory() + "/Library/Logs"
        self.basePath = logsDir + "/ClaudeSwitch-app.log"

        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        openHandle()
        writeSessionHeader()
    }

    private func openHandle() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: basePath) {
            fm.createFile(atPath: basePath, contents: nil)
            bytesWritten = 0
        } else {
            let attrs = try? fm.attributesOfItem(atPath: basePath)
            bytesWritten = (attrs?[.size] as? UInt64) ?? 0
        }
        fileHandle = FileHandle(forWritingAtPath: basePath)
        _ = try? fileHandle?.seekToEnd()
    }

    private func writeSessionHeader() {
        let ts = dateFormatter.string(from: Date())
        let header = "====== ClaudeSwitch launched \(ts) ======\n"
        if let data = header.data(using: .utf8) {
            fileHandle?.write(data)
            bytesWritten += UInt64(data.count)
        }
    }

    func write(_ level: String, _ category: String, _ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let ts = self.dateFormatter.string(from: Date())
            let line = "[\(ts)] [\(level)] [\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let fh = self.fileHandle {
                fh.write(data)
                self.bytesWritten += UInt64(data.count)
                if self.bytesWritten >= Self.maxFileBytes {
                    self.rotate()
                }
            }
        }
    }

    /// Rotate: close current → bump .1→.2, .log→.1 (drop oldest) → open fresh.
    /// Called only on the serial queue; safe to mutate fileHandle.
    private func rotate() {
        try? fileHandle?.close()
        fileHandle = nil

        let fm = FileManager.default
        let oldestPath = "\(basePath).\(Self.keepRotated)"
        try? fm.removeItem(atPath: oldestPath)

        var idx = Self.keepRotated
        while idx > 1 {
            let from = "\(basePath).\(idx - 1)"
            let to = "\(basePath).\(idx)"
            if fm.fileExists(atPath: from) {
                try? fm.moveItem(atPath: from, toPath: to)
            }
            idx -= 1
        }

        let firstRotated = "\(basePath).1"
        try? fm.removeItem(atPath: firstRotated)
        if fm.fileExists(atPath: basePath) {
            try? fm.moveItem(atPath: basePath, toPath: firstRotated)
        }

        openHandle()
        let ts = dateFormatter.string(from: Date())
        let marker = "====== rotated at \(ts) ======\n"
        if let data = marker.data(using: .utf8) {
            fileHandle?.write(data)
            bytesWritten += UInt64(data.count)
        }
    }
}
