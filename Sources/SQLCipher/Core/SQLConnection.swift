//
//  SQLConnection.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 2/7/25.
//  Copyright © 2025 Dimension North Inc. All rights reserved.
//

import Foundation
import OSLog

import CSQLCipher

public final class SQLConnection {
    /// An enumeration representing the role of a database connection, defining
    /// whether it is a read-only connection or a writable connection.
    ///
    /// The `Role` enum provides specialized behaviors for read-only and writable
    /// connections. For read-only connections, a concurrent queue is used and
    /// commits will return `SQLITE_MISUSE` if attempted. For writable connections,
    /// a serial queue is used, and an `onUpdate` callback is provided to customize
    /// commit behavior.
    public enum Role {
        /// A read-only connection role.
        ///
        /// This role uses a concurrent dispatch queue for maximum read concurrency,
        /// and any attempt to perform a write operation will return an error
        /// (`SQLITE_MISUSE`). It is intended strictly for read operations.
        case reader
        
        /// A writable connection role.
        ///
        /// This role uses a serial dispatch queue to serialize write operations.
        case writer
        
        /// The queue associated with the connection's role.
        ///
        /// - For `.reader`, a concurrent queue is returned, enabling multiple
        ///   read operations to execute concurrently.
        /// - For `.writer`, a serial queue is returned, ensuring write operations
        ///   are performed one at a time.
        var queue: DispatchQueue {
            switch self {
            case .reader:
                return DispatchQueue(
                    label: "com.dimension-north.SQLCipher.Connection.reader.\(UUID())",
                    attributes: .concurrent
                )
            case .writer:
                return DispatchQueue(
                    label: "com.dimension-north.SQLCipher.Connection.writer.\(UUID())"
                )
            }
        }
        
        /// The callback function that handles updates on the connection.
        ///
        /// - For `.reader`, this function always returns `SQLITE_MISUSE`, enforcing
        ///   the read-only behavior by prohibiting commit operations.
        /// - For `.writer`, this function always returns `SQLITE_OK`, allowing
        ///   all commit operations..
        var onUpdate: (SQLConnection) -> SQLErrorCode {
            switch self {
            case .reader:
                return { _ in return SQLITE_MISUSE }
            case .writer:
                return { _ in return SQLITE_OK }
            }
        }
    }
    
    // SQLite database connection
    let db: OpaquePointer
    let queue: DispatchQueue
    
    public  var onUpdate: (SQLConnection) -> SQLErrorCode
    
    public private(set) var isEncrypted: Bool = false
    
    // Package-internal logger for SQLCipher operations
    static let log = Logger(subsystem: "com.dimension-north.SQLCipher", category: "Connection")
    
    public init(path: String, key: String? = nil, role: Role) throws {
        let key = key ?? ""
        
        self.queue = role.queue
        self.onUpdate = role.onUpdate
        
        var db: OpaquePointer?
        try checked(sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil))
        
        guard let db else {
            throw SQLError(error: "Failed to initialize database connection")
        }
        
        self.db = db

        // Set the encryption key if provided
        if !key.isEmpty {
            // Verify that the database can be accessed
            do {
                try setKey(key)
                try verifyAccessibility()
            } catch {
                sqlite3_close_v2(db)
                throw error
            }

            isEncrypted = true
        }

        // Install commit, rollback hooks
        installCommitHooks()
    }
    
    deinit {
        sqlite3_close_v2(db)
    }

    /// Sets the encryption key for the database connection.
    ///
    /// If `nil` or an empty string is passed as the key, it assumes the database is not encrypted.
    ///
    /// - Parameter key: The encryption key to set for the database connection.
    ///   Pass `nil` or an empty string if the database is not encrypted.
    /// - Throws: An `SQLiteError` if the operation fails.
    private func setKey(_ key: String?) throws {
        let keyToUse = key ?? ""
        try checked(sqlite3_key(self.db, keyToUse, Int32(keyToUse.utf8.count)))
    }
    
    /// Verifies that the database is accessible by executing a simple
    /// query on the `sqlite_master` table.
    ///
    /// This function prepares and steps through a query that counts the
    /// entries in `sqlite_master`, which is the system catalog of SQLite.
    /// If the query preparation or execution fails, an error is thrown.
    ///
    /// - Throws: An `SQLiteError` if the database cannot be accessed.
    private func verifyAccessibility() throws {
        let sql = "SELECT count(*) FROM sqlite_master;"
        var stmt: OpaquePointer?
        
        // Prepare the SQL statement and validate success.
        try checked(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        
        // Ensure the statement is finalized to free resources.
        defer { sqlite3_finalize(stmt) }
        
        // Execute the query and check the result.
        let stepResult = sqlite3_step(stmt)
        if stepResult != SQLITE_ROW && stepResult != SQLITE_DONE {
            throw SQLError(code: sqlite3_errcode(db))
        }
    }
    
    /// Resets the database encryption with a new encryption key.
    ///
    /// If `nil` or an empty string is passed as the new key,
    /// database encryption will be removed.
    ///
    /// - Parameter key: The new encryption key. Pass `nil` or an empty
    ///   string to remove encryption.
    /// - Throws: An `SQLiteError` if the rekeying operation fails.
    public func resetKey(_ key: String?) throws {
        let keyToUse = key ?? ""

        if isEncrypted {
            // rekey when we're resetting the key on an already encrypted database
            try checked(sqlite3_rekey(self.db, keyToUse, Int32(keyToUse.utf8.count)))
        } else if !keyToUse.isEmpty {
            // if our database is unkeyed, only set a key if it is non-empty
            try checked(sqlite3_key(self.db, keyToUse, Int32(keyToUse.utf8.count)))
        }

        isEncrypted = !keyToUse.isEmpty
    }
}

// MARK: - Commit, Rollback Hook Integration

extension SQLConnection {
    /// Installs commit and rollback hooks on the SQLite database connection.
    ///
    /// The `sqlite3_commit_hook` and `sqlite3_rollback_hook` functions are
    /// used to register callbacks for database commit and rollback events,
    /// respectively. These callbacks invoke `commitHookCallback` and
    /// `rollbackHookCallback`, which in turn call the instance methods
    /// `onCommit` and `onRollback`.
    private func installCommitHooks() {
        sqlite3_commit_hook(self.db, commitHookCallback, Unmanaged.passUnretained(self).toOpaque())
        sqlite3_rollback_hook(self.db, rollbackHookCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Callback for commit events in the SQLite database connection.
    ///
    /// This method is triggered whenever a transaction is successfully committed
    /// to the database.
    ///
    /// - Returns: the result of `onUpdate(self)`
    fileprivate func onCommit() -> SQLErrorCode {
        return onUpdate(self)
    }
    
    /// Callback for rollback events in the SQLite database connection.
    ///
    /// This method is called whenever a transaction is rolled back in the
    /// database, either due to an explicit rollback or because of an error
    /// during the transaction.
    fileprivate func onRollback() {
        _ = onUpdate(self)
    }
}

// C-style function for commit callback
///
/// This function is registered with SQLite as a C-style callback for commit
/// events. It converts the opaque context pointer to a `Connection` instance
/// and then calls `onCommit` on that instance.
///
/// - Parameter context: An opaque pointer to the `Connection` instance.
/// - Returns: `SQLITE_OK` if the commit can proceed, or `SQLITE_DENY` to
///   abort the commit.
private func commitHookCallback(context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    let connection = Unmanaged<SQLConnection>.fromOpaque(context).takeUnretainedValue()
    return connection.onCommit()
}

// C-style function for rollback callback
///
/// This function is registered with SQLite as a C-style callback for rollback
/// events. It converts the opaque context pointer to a `Connection` instance
/// and then calls `onRollback` on that instance.
///
/// - Parameter context: An opaque pointer to the `Connection` instance.
private func rollbackHookCallback(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let connection = Unmanaged<SQLConnection>.fromOpaque(context).takeUnretainedValue()
    connection.onRollback()
}

extension SQLConnection {
    public func begin() throws {
        try exec("BEGIN TRANSACTION;")
    }
    
    public func commit() throws {
        try exec("COMMIT;")
    }
    
    public func rollback() throws {
        try exec("ROLLBACK;")
    }
    
    public func exec(_ sql: String) throws {
        try queue.sync {
            Self.log.debug(
                "executing: \(sql, privacy: .public)"
            )
            try checked(sqlite3_exec(self.db, sql, nil, nil, nil))
        }
    }
        
    /// Prepares a SQLQuery for execution
    ///
    /// - Parameter query: The query to prepare
    /// - Returns: A prepared query ready for execution
    /// - Throws: If preparation fails
    public func prepare<Params>(_ query: SQLQuery<Params>) throws -> SQLPreparedQuery<Params> {
        return try query.prepared(for: self)
    }
    
    /// Executes a query with parameters
    ///
    /// - Parameters:
    ///   - query: The query to execute
    ///   - params: Parameters to bind to the query
    /// - Returns: The query result
    /// - Throws: If execution fails
    @discardableResult
    public func execute<Params>(_ query: SQLQuery<Params>, _ params: Params) throws -> SQLResult {
        try queue.sync {
            return try query.prepared(for: self).execute(params)
        }
    }
    
    /// Executes a parameter-less query
    ///
    /// - Parameter query: The query to execute
    /// - Returns: The query result
    /// - Throws: If execution fails
    @discardableResult
    public func execute(_ query: SQLQuery<Void>) throws -> SQLResult {
        return try query.prepared(for: self).execute()
    }
}
