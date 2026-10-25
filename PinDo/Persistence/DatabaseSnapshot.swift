import Foundation
import SQLite3

enum DatabaseSnapshot {
    /// SQLite's backup API includes committed WAL pages in one consistent database snapshot.
    /// https://www.sqlite.org/backup.html
    static func copy(from source: URL, to destination: URL) throws {
        var reader: OpaquePointer?
        var writer: OpaquePointer?
        guard sqlite3_open_v2(source.path, &reader, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let reader { sqlite3_close(reader) }
            throw StoreFailure.inconsistentStore
        }
        defer { sqlite3_close(reader) }
        guard sqlite3_open_v2(destination.path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let writer { sqlite3_close(writer) }
            throw StoreFailure.inconsistentStore
        }
        defer { sqlite3_close(writer) }
        sqlite3_busy_timeout(reader, 500)
        sqlite3_busy_timeout(writer, 500)
        guard let transfer = sqlite3_backup_init(writer, "main", reader, "main") else { throw StoreFailure.inconsistentStore }
        let result = sqlite3_backup_step(transfer, -1)
        let finished = sqlite3_backup_finish(transfer)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { throw StoreFailure.inconsistentStore }
        guard sqlite3_exec(writer, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else { throw StoreFailure.inconsistentStore }
    }
}

