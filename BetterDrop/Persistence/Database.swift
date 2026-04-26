import Foundation
import SQLite3

// SQLite3 persistence for transfers and devices.
// All writes happen on a dedicated serial queue; reads are synchronous on the caller.
// Schema is created on first launch; migrations append new columns.

actor Database {
    static let shared = Database()

    private var db: OpaquePointer?
    private let dbURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("BetterDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("betterdrop.sqlite3")
    }()

    // MARK: - Open / schema

    func open() throws {
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw DBError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        try execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
        """)
        try createSchema()
    }

    private func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS devices (
                id          TEXT PRIMARY KEY,
                name        TEXT NOT NULL,
                platform    TEXT NOT NULL,
                last_seen   REAL NOT NULL,
                is_trusted  INTEGER NOT NULL DEFAULT 0,
                color_r     REAL NOT NULL DEFAULT 0.35,
                color_g     REAL NOT NULL DEFAULT 0.53,
                color_b     REAL NOT NULL DEFAULT 0.94
            );

            CREATE TABLE IF NOT EXISTS transfers (
                id              TEXT PRIMARY KEY,
                device_id       TEXT NOT NULL REFERENCES devices(id),
                status          TEXT NOT NULL,
                queued_at       REAL NOT NULL,
                started_at      REAL,
                completed_at    REAL,
                progress        REAL NOT NULL DEFAULT 0,
                error_message   TEXT,
                retry_count     INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS transfer_files (
                id          TEXT PRIMARY KEY,
                transfer_id TEXT NOT NULL REFERENCES transfers(id) ON DELETE CASCADE,
                name        TEXT NOT NULL,
                size        INTEGER NOT NULL,
                uti         TEXT NOT NULL,
                local_url   TEXT NOT NULL,
                sort_order  INTEGER NOT NULL DEFAULT 0
            );

            CREATE INDEX IF NOT EXISTS idx_transfers_device ON transfers(device_id);
            CREATE INDEX IF NOT EXISTS idx_transfers_status ON transfers(status);
        """)
    }

    // MARK: - Devices

    func upsertDevice(_ device: Device) throws {
        try execute(
            "INSERT OR REPLACE INTO devices(id,name,platform,last_seen,is_trusted,color_r,color_g,color_b) VALUES(?,?,?,?,?,?,?,?)",
            device.id.uuidString,
            device.name,
            device.platform.rawValue,
            device.lastSeen.timeIntervalSince1970,
            device.isTrusted ? 1 : 0,
            device.avatarColor.red,
            device.avatarColor.green,
            device.avatarColor.blue
        )
    }

    func loadDevices() throws -> [Device] {
        try query("SELECT id,name,platform,last_seen,is_trusted,color_r,color_g,color_b FROM devices") { stmt in
            Device(
                id: UUID(uuidString: column(stmt, 0)) ?? UUID(),
                name: column(stmt, 1),
                platform: DevicePlatform(rawValue: column(stmt, 2)) ?? .unknown,
                lastSeen: Date(timeIntervalSince1970: columnDouble(stmt, 3)),
                isOnline: false,  // runtime-only; set by DeviceRegistry
                avatarColor: CodableColor(red: columnDouble(stmt, 5), green: columnDouble(stmt, 6), blue: columnDouble(stmt, 7)),
                isTrusted: columnInt(stmt, 4) != 0
            )
        }
    }

    // MARK: - Transfers

    func insertTransfer(_ transfer: Transfer) throws {
        try execute(
            "INSERT INTO transfers(id,device_id,status,queued_at,progress,retry_count) VALUES(?,?,?,?,?,?)",
            transfer.id.uuidString,
            transfer.targetDeviceID.uuidString,
            transfer.status.rawValue,
            transfer.queuedAt.timeIntervalSince1970,
            transfer.progress,
            transfer.retryCount
        )
        for (i, file) in transfer.files.enumerated() {
            try execute(
                "INSERT INTO transfer_files(id,transfer_id,name,size,uti,local_url,sort_order) VALUES(?,?,?,?,?,?,?)",
                file.id.uuidString,
                transfer.id.uuidString,
                file.name,
                Int64(file.size),
                file.uti,
                file.localURL.path,
                i
            )
        }
    }

    func markCompleted(transferID: UUID) throws {
        try execute(
            "UPDATE transfers SET status='completed', completed_at=?, progress=1.0 WHERE id=?",
            Date().timeIntervalSince1970,
            transferID.uuidString
        )
    }

    func markFailed(transferID: UUID, error: String) throws {
        try execute(
            "UPDATE transfers SET status='failed', error_message=?, retry_count=retry_count+1 WHERE id=?",
            error,
            transferID.uuidString
        )
    }

    func updateStatus(_ status: TransferStatus, for transferID: UUID) throws {
        try execute("UPDATE transfers SET status=? WHERE id=?", status.rawValue, transferID.uuidString)
    }

    func loadTransfers() throws -> [Transfer] {
        let files: [String: [TransferFile]] = try loadAllFiles()
        return try query(
            "SELECT id,device_id,status,queued_at,started_at,completed_at,progress,error_message,retry_count FROM transfers ORDER BY queued_at DESC"
        ) { stmt in
            let id = column(stmt, 0)
            return Transfer(
                id: UUID(uuidString: id) ?? UUID(),
                targetDeviceID: UUID(uuidString: column(stmt, 1)) ?? UUID(),
                files: files[id] ?? [],
                status: TransferStatus(rawValue: column(stmt, 2)) ?? .failed,
                queuedAt: Date(timeIntervalSince1970: columnDouble(stmt, 3)),
                startedAt: columnOptionalDate(stmt, 4),
                completedAt: columnOptionalDate(stmt, 5),
                progress: columnDouble(stmt, 6),
                errorMessage: columnOptional(stmt, 7),
                retryCount: columnInt(stmt, 8)
            )
        }
    }

    private func loadAllFiles() throws -> [String: [TransferFile]] {
        var map: [String: [TransferFile]] = [:]
        let rows: [(String, TransferFile)] = try query(
            "SELECT transfer_id,id,name,size,uti,local_url FROM transfer_files ORDER BY sort_order"
        ) { stmt in
            let tid = column(stmt, 0)
            let file = TransferFile(
                id: UUID(uuidString: column(stmt, 1)) ?? UUID(),
                name: column(stmt, 2),
                size: Int64(columnInt(stmt, 3)),
                uti: column(stmt, 4),
                localURL: URL(fileURLWithPath: column(stmt, 5))
            )
            return (tid, file)
        }
        for (tid, file) in rows {
            map[tid, default: []].append(file)
        }
        return map
    }

    // MARK: - SQLite helpers

    private func execute(_ sql: String, _ params: Any?...) throws {
        // Split on ';' to handle multi-statement strings
        for statement in sql.components(separatedBy: ";").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, statement, -1, &stmt, nil) == SQLITE_OK else {
                throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            for (i, param) in params.enumerated() {
                let idx = Int32(i + 1)
                switch param {
                case let s as String:   sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                case let d as Double:   sqlite3_bind_double(stmt, idx, d)
                case let i as Int:      sqlite3_bind_int64(stmt, idx, Int64(i))
                case let i as Int64:    sqlite3_bind_int64(stmt, idx, i)
                case nil:              sqlite3_bind_null(stmt, idx)
                default: break
                }
            }

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DBError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func query<T>(_ sql: String, _ map: (OpaquePointer?) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(map(stmt))
        }
        return results
    }

    private func column(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        String(cString: sqlite3_column_text(stmt, i))
    }
    private func columnDouble(_ stmt: OpaquePointer?, _ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    private func columnInt(_ stmt: OpaquePointer?, _ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    private func columnOptional(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        sqlite3_column_text(stmt, i).map { String(cString: $0) }
    }
    private func columnOptionalDate(_ stmt: OpaquePointer?, _ i: Int32) -> Date? {
        let v = sqlite3_column_double(stmt, i)
        return v > 0 ? Date(timeIntervalSince1970: v) : nil
    }
}

enum DBError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
}
