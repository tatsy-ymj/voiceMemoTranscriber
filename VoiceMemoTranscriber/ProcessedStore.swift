import CryptoKit
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ProcessedStore {
    enum Status: String, Codable {
        case success
        case failed
    }

    struct RecentRecord: Identifiable {
        let id: String
        let path: String
        let status: Status
        let errorMessage: String?
        let processedAt: Date

        var fileName: String {
            if path.isEmpty { return "(unknown file)" }
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    private struct LegacyStored: Codable {
        var items: [String: Status]
    }

    private let queue = DispatchQueue(label: "voice.memo.transcriber.processed.store")
    private let dbURL: URL
    private let legacyJSONURL: URL
    private var db: OpaquePointer?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceMemoTranscriber", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dbURL = base.appendingPathComponent(AppConstants.processedStoreDBFileName)
        legacyJSONURL = base.appendingPathComponent(AppConstants.processedStoreLegacyJSONFileName)

        queue.sync {
            openDB()
            createSchema()
            migrateLegacyJSONIfNeeded()
        }
    }

    deinit {
        queue.sync {
            if let db {
                sqlite3_close(db)
                self.db = nil
            }
        }
    }

    func isProcessed(fingerprint: String) -> Bool {
        queue.sync {
            guard let db else { return false }
            let sql = "SELECT 1 FROM processed_records WHERE fingerprint = ? LIMIT 1;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            sqlite3_bind_text(stmt, 1, fingerprint, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    func markProcessed(
        fingerprint: String,
        path: String,
        size: UInt64,
        mtime: TimeInterval,
        status: Status,
        errorMessage: String? = nil
    ) {
        queue.sync {
            guard let db else { return }
            let sql = """
            INSERT INTO processed_records (fingerprint, path, size, mtime, status, error_message, processed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(fingerprint) DO UPDATE SET
                path = excluded.path,
                size = excluded.size,
                mtime = excluded.mtime,
                status = excluded.status,
                error_message = excluded.error_message,
                processed_at = excluded.processed_at;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            sqlite3_bind_text(stmt, 1, fingerprint, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, sqlite3_int64(size))
            sqlite3_bind_double(stmt, 4, mtime)
            sqlite3_bind_text(stmt, 5, status.rawValue, -1, SQLITE_TRANSIENT)
            if let errorMessage, !errorMessage.isEmpty {
                sqlite3_bind_text(stmt, 6, errorMessage, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)

            _ = sqlite3_step(stmt)
        }
    }

    func recentResults(limit: Int) -> [RecentRecord] {
        queue.sync {
            guard let db else { return [] }
            let sql = """
            SELECT fingerprint, path, status, error_message, processed_at
            FROM processed_records
            ORDER BY processed_at DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var records: [RecentRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let fpPtr = sqlite3_column_text(stmt, 0),
                      let statusPtr = sqlite3_column_text(stmt, 2) else {
                    continue
                }
                let fingerprint = String(cString: fpPtr)
                let path = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let statusRaw = String(cString: statusPtr)
                guard let status = Status(rawValue: statusRaw) else { continue }
                let errorMessage = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let processedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                records.append(
                    RecentRecord(
                        id: fingerprint,
                        path: path,
                        status: status,
                        errorMessage: errorMessage,
                        processedAt: processedAt
                    )
                )
            }
            return records
        }
    }

    static func fingerprint(path: String, size: UInt64, mtime: TimeInterval) -> String {
        let raw = "\(path)|\(size)|\(mtime)"
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func openDB() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            db = nil
        }
    }

    private func createSchema() {
        guard let db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS processed_records (
            fingerprint TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            size INTEGER NOT NULL,
            mtime REAL NOT NULL,
            status TEXT NOT NULL,
            error_message TEXT,
            processed_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_processed_records_processed_at
        ON processed_records(processed_at DESC);
        """
        _ = sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func migrateLegacyJSONIfNeeded() {
        guard let db else { return }
        guard FileManager.default.fileExists(atPath: legacyJSONURL.path) else { return }
        guard let data = try? Data(contentsOf: legacyJSONURL),
              let legacy = try? JSONDecoder().decode(LegacyStored.self, from: data) else {
            return
        }

        let now = Date().timeIntervalSince1970
        var idx: Double = 0
        for (fingerprint, status) in legacy.items {
            let sql = """
            INSERT OR IGNORE INTO processed_records (fingerprint, path, size, mtime, status, error_message, processed_at)
            VALUES (?, '', 0, 0, ?, NULL, ?);
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, fingerprint, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, now - idx)
            _ = sqlite3_step(stmt)
            idx += 0.001
        }
    }
}
