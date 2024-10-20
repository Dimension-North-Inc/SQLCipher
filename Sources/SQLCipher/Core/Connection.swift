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
        var onUpdate: (Connection) -> SQLErrorCode {
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
    public  var onUpdate: (Connection) -> SQLErrorCode
    
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
            throw SQLError(code: sqlite3_errcode(db))
        }
    }
    
    /// Sets the encryption key for the database connection.
    ///
    /// If `nil` or an empty string is passed as the key, it assumes the database is not encrypted.
    ///
    /// - Parameter key: The encryption key to set for the database connection.
    ///   Pass `nil` or an empty string if the database is not encrypted.
    /// - Throws: An `SQLiteError` if the operation fails.
    public func setKey(_ key: String?) throws {
        let keyToUse = key ?? ""
        try checked(sqlite3_key(self.db, keyToUse, Int32(keyToUse.utf8.count)))
    }
    
    /// Resets the database encryption with a new encryption key.
    ///
    /// If `nil` or an empty string is passed as the new key,
    /// database encryption will be removed.
    ///
    /// - Parameter key: The new encryption key. Pass `nil` or an empty
    ///   string to remove encryption.
    /// - Throws: An `SQLiteError` if the rekeying operation fails.
    public func resetKey(to key: String?) throws {
        let keyToUse = key ?? ""
        try checked(sqlite3_rekey(self.db, keyToUse, Int32(keyToUse.utf8.count)))
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

extension Connection: Database {
    /// Begins a new transaction in the database.
    ///
    /// This method initiates a transaction, grouping multiple database operations
    /// into a single atomic operation. Changes made during the transaction are not
    /// saved to the database until a `commit` is executed. If an error occurs
    /// during the transaction, `rollback` can be used to revert changes.
    ///
    /// - Throws: An error if the transaction cannot be started.
    public func begin() throws {
        try exec("BEGIN TRANSACTION;")
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
        try exec("COMMIT;")
    }
    
    /// Rolls back the current transaction in the database.
    ///
    /// This method cancels all changes made during the current transaction, reverting
    /// the database to the state it was in before `begin` was called. This is useful
    /// for error recovery or if an operation within the transaction fails.
    ///
    /// - Throws: An error if the transaction cannot be rolled back.
    public func rollback() throws {
        try exec("ROLLBACK;")
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
                throw SQLError(code: result)
            }
        }
    }

    /// Executes a query without named bindings.
    ///
    /// - Parameter sql: A SQL query without bindings.
    /// - Throws: An error if the execution of any command fails.
    @discardableResult
    public func execute(_ sql: String) throws -> [SQLRow] {
        try execute(sql, with: [])
    }

    /// Executes a query with positional bindings and returns the result as an array of `Row`.
    ///
    /// - Parameters:
    ///   - sql: The SQL query with positional placeholders.
    ///   - values: An array of `Value` objects to bind positionally.
    /// - Returns: An array of `Row` objects representing the query result.
    /// - Throws: An `SQLiteError` if the query fails.
    @discardableResult
    public func execute(_ sql: String, with values: [SQLValue]) throws -> [SQLRow] {
        var statement: OpaquePointer?
        var rows: [SQLRow] = []
        
        var updatedSQL = sql
        var expandedValues: [SQLValue] = []

        try queue.sync {
            // Expand `Value.array` items into individual positional placeholders
            for value in values {
                switch value {
                case .array(let elements):
                    // Replace the first `?` found with placeholders for each element
                    let placeholders = elements.map { _ in "?" }.joined(separator: ", ")
                    if let range = updatedSQL.range(of: "?") {
                        updatedSQL.replaceSubrange(range, with: placeholders)
                    }
                    expandedValues.append(contentsOf: elements)
                default:
                    expandedValues.append(value)
                }
            }
            
            // Log the SQL with arguments
            let args = expandedValues.map(\.description).joined(separator: ", ")
            Connection.log.debug("Executing SQL query: \(updatedSQL, privacy: .public) with arguments: \(args, privacy: .public)")
            
            try checked(sqlite3_prepare_v2(db, updatedSQL, -1, &statement, nil))
            
            guard let statement else {
                throw SQLError(misuse: "Failed to prepare SQL statement.")
            }
            
            defer { sqlite3_finalize(statement) }
            
            // Bind expanded positional values
            for (index, value) in expandedValues.enumerated() {
                try value.bind(to: statement, at: Int32(index + 1))
            }
            
            // Step through the rows and collect results
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(SQLRow(statement: statement))
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
    @discardableResult
    public func execute(_ sql: String, with values: [String: SQLValue]) throws -> [SQLRow] {
        var statement: OpaquePointer?
        var rows: [SQLRow] = []
        
        var updatedSQL = sql
        var expandedBindings: [String: SQLValue] = [:]

        try queue.sync {
            // Process each named parameter for array expansion
            for (key, value) in values {
                switch value {
                case .array(let elements):
                    // Generate placeholders for each element in the array
                    let expandedPlaceholders = elements.enumerated().map { "\(key)_\($0.offset)" }
                    let placeholderString = expandedPlaceholders.map { ":\($0)" }.joined(separator: ", ")
                    
                    // Replace `:key` with `:key_0, :key_1, ...` in the SQL
                    updatedSQL = updatedSQL.replacingOccurrences(of: ":\(key)", with: placeholderString)
                    
                    // Add each element to the expanded bindings
                    for (index, element) in elements.enumerated() {
                        expandedBindings["\(key)_\(index)"] = element
                    }
                    
                default:
                    expandedBindings[key] = value
                }
            }

            // Log the SQL with arguments
            let args = expandedBindings.map { "\($0.key) = \($0.value)" }.joined(separator: ", ")
            Connection.log.debug("Executing SQL query: \(updatedSQL, privacy: .public) with arguments: \(args, privacy: .public)")

            try checked(sqlite3_prepare_v2(db, updatedSQL, -1, &statement, nil))

            guard let statement else {
                throw SQLError(misuse: "Failed to prepare SQL statement.")
            }

            defer { sqlite3_finalize(statement) }

            // Bind the expanded named values
            for (name, value) in expandedBindings {
                let index = sqlite3_bind_parameter_index(statement, ":\(name)")
                try value.bind(to: statement, at: index)
            }
            
            // Step through the rows and collect results
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(SQLRow(statement: statement))
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
    
    /// Executes an asynchronous block that has access to the `Connection` instance.
    ///
    /// This method passes the `Connection` instance itself to the closure,
    /// allowing the block to call public methods that handle the queue as
    /// needed.
    ///
    /// - Parameter block: An asynchronous closure that takes the `Connection` instance as
    ///   an argument, allowing access to its public methods.
    internal func performTask<T>(_ block: (Connection) async throws -> T) async rethrows -> T {
        return try await block(self)
    }
}

