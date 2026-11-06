import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "com.hayato.configbox", category: "app")
    static func info(_ s: String)  { logger.info("\(s, privacy: .public)"); file("INFO", s) }
    static func error(_ s: String) { logger.error("\(s, privacy: .public)"); file("ERROR", s) }
    static func debug(_ s: String) { logger.debug("\(s, privacy: .public)"); file("DEBUG", s) }

    // Small plain-text log for bug reports: ~/Library/Logs/ConfigBox.log (truncated when it grows past 1 MB).
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ConfigBox.log")
    private static let queue = DispatchQueue(label: "configbox.log", qos: .utility)
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
    private static func file(_ level: String, _ s: String) {
        let line = "\(stamp.string(from: Date())) [\(level)] \(s)\n"
        queue.async {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path), (attrs[.size] as? Int ?? 0) > 1_000_000 {
                try? FileManager.default.removeItem(at: fileURL)
            }
            if let h = try? FileHandle(forWritingTo: fileURL) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: fileURL)
            }
        }
    }
}
