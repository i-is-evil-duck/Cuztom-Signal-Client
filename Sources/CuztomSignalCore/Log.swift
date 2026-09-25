import Foundation

/// Local diagnostics log. Never leaves the machine; provisioning URLs and
/// message bodies are never written here (counts and ids only).
public enum Log {
    public static let fileURL: URL = {
        let base = (try? FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)) ?? FileManager.default.temporaryDirectory
        // A test run and a running app both log here by default, which makes the
        // log useless for diagnosing the app: the test suite reads and creates
        // its own Keychain accounts and buries the real entries. `CUZTOM_LOG_PATH`
        // points a run somewhere else.
        if let override = ProcessInfo.processInfo.environment["CUZTOM_LOG_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return base.appendingPathComponent("Logs/CuztomSignal/app.log")
    }()

    private static let queue = DispatchQueue(label: "cuztom-signal.log")
    private static let maxBytes = 5 * 1024 * 1024
    private static let retainedBytes = 2 * 1024 * 1024
    private static let uuidRegex = try? NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    )
    private static let pathRegex = try? NSRegularExpression(
        pattern: "/(?:Users|private|var|tmp)/[^\\s]+"
    )
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func info(_ message: String) {
        write("INFO", message)
    }

    public static func error(_ message: String) {
        write("ERROR", message)
    }

    /// Remove retained diagnostics after an authoritative account wipe. The
    /// native stdout/stderr descriptor may still point at this inode, so use
    /// truncation rather than unlinking it.
    public static func clear() {
        queue.async {
            do {
                let dir = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: fileURL.path
                )
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
            } catch {
                print("[CuztomSignal] log clear failed: \(error)")
            }
        }
    }

    private static func redact(_ message: String) -> String {
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        var value = message
        if let uuidRegex {
            value = uuidRegex.stringByReplacingMatches(in: value, range: range, withTemplate: "<redacted-id>")
        }
        if let pathRegex {
            let refreshed = NSRange(value.startIndex..<value.endIndex, in: value)
            value = pathRegex.stringByReplacingMatches(in: value, range: refreshed, withTemplate: "<redacted-path>")
        }
        return String(value.prefix(2_000))
    }

    private static func trimIfNeeded(_ handle: FileHandle) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > maxBytes else { return }
        let keep = min(retainedBytes, Int(size))
        try handle.seek(toOffset: size - UInt64(keep))
        let tail = handle.readData(ofLength: keep)
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("[older diagnostics truncated]\n".utf8))
        try handle.write(contentsOf: tail)
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(dateFmt.string(from: Date())) [\(level)] \(redact(message))\n"
        // Deliberately not also printed to stdout. The app redirects stdout and
        // stderr into this same file so that native output — Rust `eprintln!`
        // and panic messages — is not lost, so printing here would write every
        // line twice. The duplicate copies made counts taken from this log
        // wrong, which matters when the log is the evidence for a bug.
        queue.async {
            do {
                let dir = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: fileURL.path
                )
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try trimIfNeeded(handle)
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                // The file handle is gone, so there is nowhere to write this.
                // stderr is redirected into the log file too, so this still
                // lands in the diagnostics rather than vanishing.
                FileHandle.standardError.write(
                    Data("[CuztomSignal] log write failed: \(error)\n".utf8)
                )
            }
        }
    }
}
