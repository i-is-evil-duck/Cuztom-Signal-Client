import Foundation

/// Local diagnostics log. Never leaves the machine; provisioning URLs and
/// message bodies are never written here (counts and ids only).
public enum Log {
    public static let fileURL: URL = {
        let base = (try? FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)) ?? FileManager.default.temporaryDirectory
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
        print("[CuztomSignal] \(line)", terminator: "")
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
                print("[CuztomSignal] log write failed: \(error)")
            }
        }
    }
}
