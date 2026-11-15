import Foundation

/// A small log file, ~/Library/Logs/Harf/harf.log (docs/logging.md). Callable from any thread. Every line is also written to
/// stderr as `harf: ...`. Never log what a program printed or what the user typed: only what Harf itself did.
enum Log {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started = false   // the file is written only after start(): the self-test and conformance runs stay out of it
    private static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Harf")
    private static let file = dir.appendingPathComponent("harf.log")
    private static let maxBytes = 1 << 20   // ponytail: one old generation (harf.log.1), no config; add a setting if 1 MiB is not enough

    static func info(_ what: String) { write("INFO ", what) }
    static func warn(_ what: String) { write("WARN ", what) }
    static func error(_ what: String) { write("ERROR", what) }

    /// Call once at launch: rotates a big file, notes a previous run that never logged `quit` (a crash leaves a report in
    /// ~/Library/Logs/DiagnosticReports), and logs the launch.
    static func start() {
        lock.lock()
        started = true
        let old = try? String(contentsOf: file, encoding: .utf8)
        if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxBytes {
            let backup = dir.appendingPathComponent("harf.log.1")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: file, to: backup)
        }
        lock.unlock()
        if let last = old?.split(separator: "\n").last, !last.hasSuffix(" quit") {
            warn("previous run did not quit cleanly; look for Harf-*.ips in ~/Library/Logs/DiagnosticReports")
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        info("launch \(version), \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    private static func write(_ level: String, _ what: String) {
        FileHandle.standardError.write(Data("harf: \(what)\n".utf8))
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(level) \(what)\n".utf8)
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: file) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line)
    }
}
