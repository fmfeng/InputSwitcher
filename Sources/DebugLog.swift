import Foundation

/// 简单的调试日志，追加写到 ~/Desktop/inputswitcher.log。
/// 用于排查规则命中问题。可随时关闭（设 enabled=false）。
enum DebugLog {
    static var enabled = false

    private static let url: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/inputswitcher.log")
    }()

    private static let queue = DispatchQueue(label: "inputswitcher.debuglog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        guard enabled else { return }
        append(message)
    }

    /// 无视 enabled 开关，强制写入（用于捕获等需要排查的关键操作）。
    static func forceWrite(_ message: String) {
        append(message)
    }

    private static func append(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
