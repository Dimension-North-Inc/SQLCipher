//
//  Connection.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 10/15/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import Foundation
import CSQLCipher
import OSLog

public final class Connection {
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
        var onUpdate: (Connection) -> SQLiteErrorCode {
            switch self {
            case .reader:
                return { _ in return SQLITE_MISUSE }
            case .writer:
                return { _ in return SQLITE_OK }
            }
        }
    }
    
    // SQLite database connection
    private let db: OpaquePointer?
    
    private let queue: DispatchQueue
    public  var onUpdate: (Connection) -> SQLiteErrorCode
    
    
    // Package-internal logger for SQLCipher operations
    internal static let log = Logger(subsystem: "com.dimension-north.SQLCipher", category: "Connection")
    
    public init(path: String, key: String? = nil, role: Role) throws {
        self.queue = role.queue
        self.onUpdate = role.onUpdate
        
        var db: OpaquePointer?
        try checked(sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil))
        self.db = db

        // Set the encryption key if provided
        if let key {
            try checked(sqlite3_key(db, key, Int32(key.utf8.count)))
        }

        // Verify that the database can be accessed
        do {
            try self.verifyAccessibility()
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
        
        // Install commit, rollback hooks
        installCommitHooks()
    }
    
    deinit {
        if let db {
            // Close the SQLite database when the object is deallocated
            sqlite3_close_v2(db)
        }
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
            throw SQLiteError(code: sqlite3_errcode(db))
        }
    }
    
    /// Rekeys the database with a new encryption key.
    ///
    /// If `nil` or an empty string is passed as the new key, the
    /// database encryption will be removed.
    ///
    /// - Parameter key: The new encryption key. Pass `nil` or an empty
    ///   string to remove encryption.
    /// - Throws: An `SQLiteError` if the rekeying operation fails.
    public func rekey(to key: String?) throws {
        let replacement = key ?? ""
        try checked(sqlite3_rekey(self.db, replacement, Int32(replacement.utf8.count)))
    }
}

// MARK: - Commit, Rollback Hook Integration

extension Connection {
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
    fileprivate func onCommit() -> SQLiteErrorCode {
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
    let connection = Unmanaged<Connection>.fromOpaque(context).takeUnretainedValue()
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
    let connection = Unmanaged<Connection>.fromOpaque(context).takeUnretainedValue()
    connection.onRollback()
}

// MARK: - Execution

extension Connection {
    /// Begins a new transaction in the database.
    ///
    /// This method initiates a transaction, grouping multiple database operations
    /// into a single atomic operation. Changes made during the transaction are not
    /// saved to the database until a `commit` is executed. If an error occurs
    /// during the transaction, `rollback` can be used to revert changes.
    ///
    /// - Throws: An error if the transaction cannot be started.
    public func begin() throws {
        try execute("BEGIN TRANSACTION")
    }
    
    /// Commits the current transaction to the database.
    ///
    /// This method saves all changes made during the transaction to the database.
    /// It finalizes the transaction that was started with `begin`. If `begin`
    /// was not called prior to this, calling `commit` may have no effect.
    ///
    /// - Throws: An error if the transaction cannot be committed, which may indicate
    ///   issues with the underlying database or constraints violated during the transaction.
    public func commit() throws {
        try execute("COMMIT")
    }
    
    /// Rolls back the current transaction in the database.
    ///
    /// This method cancels all changes made during the current transaction, reverting
    /// the database to the state it was in before `begin` was called. This is useful
    /// for error recovery or if an operation within the transaction fails.
    ///
    /// - Throws: An error if the transaction cannot be rolled back.
    public func rollback() throws {
        try execute("ROLLBACK")
    }

    /// Executes one or more SQL commands, separated by semicolons.
    ///
    /// - Parameter sql: The SQL commands to execute.
    /// - Throws: An `SQLiteError` if any of the commands fail.
    public func exec(_ sql: String) throws {
        try queue.sync {
            Connection.log.debug(
                "Executing SQL command: \(sql, privacy: .public)"
            )

            let result = sqlite3_exec(self.db, sql, nil, nil, nil)
            if result != SQLITE_OK {
                throw SQLiteError(code: result)
            }
        }
    }
    
    /// Executes a query with positional bindings and returns the result as an array of `Row`.
    ///
    /// - Parameters:
    ///   - sql: The SQL query with positional placeholders.
    ///   - values: An array of `Value` objects to bind positionally.
    /// - Returns: An array of `Row` objects representing the query result.
    /// - Throws: An `SQLiteError` if the query fails.
    @discardableResult
    public func execute(_ sql: String, with values: [Value] = []) throws -> [Row] {
        var statement: OpaquePointer?
        var rows: [Row] = []
        
        try queue.sync {
            let args = values.map(\.description).joined(separator: ", ")
            Connection.log.debug(
                "Executing SQL query: \(sql, privacy: .public) with arguments: \(args, privacy: .public)"
            )

            try checked(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
            
            guard let statement else {
                throw SQLiteError(misuse: "Failed to prepare SQL statement.")
            }
            
            defer { sqlite3_finalize(statement) }
            
            // Bind positional values
            for (index, value) in values.enumerated() {
                try value.bind(to: statement, at: Int32(index + 1))
            }
            
            // Step through the rows and collect results
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(Row(statement: statement))
            }
        }
        
        return rows
    }

    /// Executes a query with named bindings and returns the result as an array of `Row`.
    ///
    /// - Parameters:
    ///   - sql: The SQL query with named placeholders.
    ///   - values: A dictionary mapping placeholder names to `Value` objects.
    /// - Returns: An array of `Row` objects representing the query result.
    /// - Throws: An `SQLiteError` if the query fails.
    public func execute(_ sql: String, with values: [String: Value]) throws -> [Row] {
        var statement: OpaquePointer?
        var rows: [Row] = []
        
        try queue.sync {
            let args = values.map({ key , value in "\(key) = \(value)" }).joined(separator: ", ")
            Connection.log.debug(
                "Executing SQL query: \(sql, privacy: .public) with arguments: \(args, privacy: .public)"
            )

            try checked(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
            
            guard let statement else {
                throw SQLiteError(misuse: "Failed to prepare SQL statement.")
            }
            
            defer { sqlite3_finalize(statement) }
            
            // Bind named values
            for (name, value) in values {
                let index = sqlite3_bind_parameter_index(statement, ":\(name)")
                try value.bind(to: statement, at: index)
            }
            
            // Step through the rows and collect results
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(Row(statement: statement))
            }
        }
        
        return rows
    }
    
    /// Executes a block that has access to the `Connection` instance.
    ///
    /// This method passes the `Connection` instance itself to the closure,
    /// allowing the block to call public methods that handle the queue as
    /// needed.
    ///
    /// - Parameter block: A closure that takes the `Connection` instance as
    ///   an argument, allowing access to its public methods.
    internal func performTask<T>(_ block: (Connection) throws -> T) rethrows -> T {
        try block(self)
    }
}

/// Conformance of `Connection` to the `DB` protocol.
///
/// This extension allows `Connection` to be used wherever a `DB`-conforming
/// type is required, ensuring access to the core database functionality
/// while abstracting away details of the `Connection` type itself.
extension Connection: DB {}
