import Foundation

final class AppLogger {
    static let shared = AppLogger()

    let logFileURL: URL
    private let queue = DispatchQueue(label: "voice.memo.transcriber.logger")
    private let dateFormatter: ISO8601DateFormatter

    private init() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoiceMemoTranscriber", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        logFileURL = logsDir.appendingPathComponent("app.log")

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        dateFormatter = ISO8601DateFormatter()
    }

    func log(_ message: String) {
        write(level: "INFO", message: message)
    }

    func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private func write(level: String, message: String) {
        queue.async {
            let timestamp = self.dateFormatter.string(from: Date())
            let line = "[\(timestamp)] [\(level)] \(message)\n"
            print(line, terminator: "")

            guard let data = line.data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: self.logFileURL) else {
                return
            }

            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                print("[Logger] failed to write: \(error.localizedDescription)")
            }
        }
    }
}
