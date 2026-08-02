import Foundation
import SQLite3

enum SQLiteDatabaseError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case bindFailed(String)
    case stepFailed(String)
    case executeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(message): return "SQLite open failed: \(message)"
        case let .prepareFailed(message): return "SQLite prepare failed: \(message)"
        case let .bindFailed(message): return "SQLite bind failed: \(message)"
        case let .stepFailed(message): return "SQLite step failed: \(message)"
        case let .executeFailed(message): return "SQLite execute failed: \(message)"
        }
    }
}

final class SQLiteDatabase: @unchecked Sendable {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let handle: OpaquePointer

    init(url: URL) throws {
        let databasePath = url.path == ":memory:" || url.lastPathComponent == ":memory:"
            ? ":memory:"
            : url.path

        if databasePath != ":memory:" {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var database: OpaquePointer?
        let result = databasePath.withCString { path in
            sqlite3_open_v2(
                path,
                &database,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
        }

        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw SQLiteDatabaseError.openFailed(message)
        }

        handle = database
        do {
            try execute("PRAGMA busy_timeout = 5000;")
            try execute("PRAGMA foreign_keys = ON;")
            try execute("PRAGMA journal_mode = WAL;")
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sql.withCString { sqlPointer in
            sqlite3_exec(handle, sqlPointer, nil, nil, &errorPointer)
        }
        guard result == SQLITE_OK else {
            let message: String
            if let errorPointer {
                message = String(cString: errorPointer)
                sqlite3_free(errorPointer)
            } else {
                message = errorMessage
            }
            throw SQLiteDatabaseError.executeFailed(message)
        }
    }

    func scalarInt64(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            throw SQLiteDatabaseError.stepFailed(errorMessage)
        }
        return sqlite3_column_int64(statement, 0)
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sql.withCString { sqlPointer in
            sqlite3_prepare_v2(handle, sqlPointer, -1, &statement, nil)
        }
        guard result == SQLITE_OK, let statement else {
            throw SQLiteDatabaseError.prepareFailed(errorMessage)
        }
        return statement
    }

    func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = value.withCString {
                sqlite3_bind_text(statement, index, $0, -1, Self.transient)
            }
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw SQLiteDatabaseError.bindFailed(errorMessage)
        }
    }

    func bind(_ value: Int64, at index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw SQLiteDatabaseError.bindFailed(errorMessage)
        }
    }

    func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteDatabaseError.stepFailed(errorMessage)
        }
    }

    func changes() -> Int64 {
        Int64(sqlite3_changes(handle))
    }

    var errorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    func columnString(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, index))
        return String(
            decoding: UnsafeBufferPointer(start: pointer, count: length),
            as: UTF8.self
        )
    }
}
