import Foundation

/// Local diagnostics log. Never leaves the machine; provisioning URLs and
/// message bodies are never written here (counts and ids only).
public enum Log {
    public static let fileURL: URL = {
        let base = (try? FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Logs/CuztomSignal/app.log")
    }()

    private static let queue = DispatchQueue(label: "cuztom-signal.log")
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

    private static func write(_ level: String, _ message: String) {
        let line = "\(dateFmt.string(from: Date())) [\(level)] \(message)\n"
        print("[CuztomSignal] \(line)", terminator: "")
        queue.async {
            do {
                let dir = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
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
