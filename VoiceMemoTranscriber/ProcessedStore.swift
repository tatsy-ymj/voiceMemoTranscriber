import CryptoKit
import Foundation

final class ProcessedStore {
    enum Status: String, Codable {
        case success
        case failed
    }

    private struct Stored: Codable {
        var items: [String: Status]
    }

    private let queue = DispatchQueue(label: "voice.memo.transcriber.processed.store")
    private let fileURL: URL
    private var cache: Stored

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceMemoTranscriber", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent(AppConstants.processedStoreFileName)

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            cache = decoded
        } else {
            cache = Stored(items: [:])
        }
    }

    func isProcessed(fingerprint: String) -> Bool {
        queue.sync {
            cache.items[fingerprint] != nil
        }
    }

    func markProcessed(fingerprint: String, status: Status) {
        queue.sync {
            cache.items[fingerprint] = status
            persistLocked()
        }
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: fileURL)
        }
    }

    static func fingerprint(path: String, size: UInt64, mtime: TimeInterval) -> String {
        let raw = "\(path)|\(size)|\(mtime)"
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
