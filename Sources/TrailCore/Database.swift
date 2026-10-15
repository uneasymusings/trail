import Foundation
import SQLite3

public struct DatabaseError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One result row. Column lookups are by name.
public struct Row {
    fileprivate var values: [String: Any]

    public func int(_ column: String) -> Int? {
        (values[column] as? Int64).map(Int.init)
    }
    public func double(_ column: String) -> Double? {
        if let d = values[column] as? Double { return d }
        if let i = values[column] as? Int64 { return Double(i) }
        return nil
    }
    public func string(_ column: String) -> String? { values[column] as? String }
    public func date(_ column: String) -> Date? {
        double(column).map(Date.init(timeIntervalSince1970:))
    }
}

/// A small thread-safe wrapper over the SQLite C API with a prepared-statement cache.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private let lock = NSRecursiveLock()
    public let path: String

    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw DatabaseError(message: "Could not open \(path): \(message)")
        }
        sqlite3_busy_timeout(handle, 5_000)
        try exec("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            PRAGMA temp_store = MEMORY;
            PRAGMA cache_size = -8000;
            """)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    public func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw DatabaseError(message: message)
        }
    }

    /// Runs a statement that returns no rows. Returns the number of changed rows.
    @discardableResult
    public func run(_ sql: String, _ args: Any?...) throws -> Int {
        try run(sql, arguments: args)
    }

    @discardableResult
    public func run(_ sql: String, arguments: [Any?]) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, arguments)
        defer { sqlite3_reset(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw lastError(sql) }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ args: Any?...) throws -> [Row] {
        try query(sql, arguments: args)
    }

    public func query(_ sql: String, arguments: [Any?]) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, arguments)
        defer { sqlite3_reset(statement) }
        var rows: [Row] = []
        let columns = Int(sqlite3_column_count(statement))
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw lastError(sql) }
            var values: [String: Any] = [:]
            values.reserveCapacity(columns)
            for i in 0..<columns {
                let name = String(cString: sqlite3_column_name(statement, Int32(i)))
                switch sqlite3_column_type(statement, Int32(i)) {
                case SQLITE_INTEGER: values[name] = sqlite3_column_int64(statement, Int32(i))
                case SQLITE_FLOAT: values[name] = sqlite3_column_double(statement, Int32(i))
                case SQLITE_TEXT: values[name] = String(cString: sqlite3_column_text(statement, Int32(i)))
                default: break
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    /// The first column of every row as integers, without building rows. For large id lists.
    public func ids(_ sql: String, arguments: [Any?]) throws -> [Int] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, arguments)
        defer { sqlite3_reset(statement) }
        var ids: [Int] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw lastError(sql) }
            ids.append(Int(sqlite3_column_int64(statement, 0)))
        }
        return ids
    }

    public func scalarInt(_ sql: String, _ args: Any?...) throws -> Int? {
        let rows = try query(sql, arguments: args)
        guard let row = rows.first else { return nil }
        return row.values.values.first.flatMap { ($0 as? Int64).map(Int.init) }
    }

    public var lastInsertID: Int {
        lock.lock(); defer { lock.unlock() }
        return Int(sqlite3_last_insert_rowid(handle))
    }

    /// Runs `body` inside a transaction, holding the lock so other threads wait.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Hands SQLite's page cache back to the system. The cache refills as needed.
    public func releaseMemory() {
        lock.lock(); defer { lock.unlock() }
        if let handle { sqlite3_db_release_memory(handle) }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
                throw lastError(sql)
            }
            statements[sql] = prepared
            statement = prepared
        }
        sqlite3_clear_bindings(statement)
        for (offset, value) in args.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case nil: sqlite3_bind_null(statement, index)
            case let v as Bool: sqlite3_bind_int64(statement, index, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(statement, index, Int64(v))
            case let v as Int64: sqlite3_bind_int64(statement, index, v)
            case let v as UInt64: sqlite3_bind_int64(statement, index, Int64(bitPattern: v))
            case let v as Double: sqlite3_bind_double(statement, index, v)
            case let v as Date: sqlite3_bind_double(statement, index, v.timeIntervalSince1970)
            case let v as String: sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
            default:
                throw DatabaseError(message: "Unsupported argument type \(type(of: value!)) in \(sql)")
            }
        }
        return statement
    }

    private func lastError(_ sql: String) -> DatabaseError {
        DatabaseError(message: "\(String(cString: sqlite3_errmsg(handle))) — \(sql.prefix(120))")
    }
}
