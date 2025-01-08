//
//  SQLCipher.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 10/15/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import Combine
import Foundation
import OSLog

@_exported import CSQLCipher

/// A class for managing encrypted SQLite database connections using
/// SQLCipher. It provides separate read and write connections with
/// appropriate queue handling for concurrent reads and serialized
/// writes.
public final class SQLCipher {
    /// The file path to the SQLite database.
    public let path: String
    
    /// Separate connections for read and write operations.
    private var reader, writer: Connection
    
    /// A subject that publishes an event whenever the database is
    /// updated, allowing observers to be notified of changes.
    private let didUpdate = CurrentValueSubject<Void, Never>(())
    
    /// Package-internal logger for SQLCipher operations.
    internal static let log = Logger(
        subsystem: "com.dimension-north.SQLCipher",
        category: "SQLCipher"
    )

    /// `true` if the receiver is an encrypted database, `false` otherwise
    public private(set) var isEncrypted: Bool
    
    /// Initializes a new `SQLCipher` instance with the specified
    /// database file path and optional encryption key.
    ///
    /// - Parameters:
    ///   - path: The file path to the database. Defaults to in-memory.
    ///   - key: Optional encryption key for the database.
    /// - Throws: An error if the database connection fails.
    public init(path: String = ":memory:", key: String? = nil) throws {
        SQLCipher.log.info("connecting to: \(path)")
        self.path = path
        
        // Initialize reader, writer connections.
        self.reader = try Connection(path: path, key: key, role: .reader)
        self.writer = try Connection(path: path, key: key, role: .writer)
        
        self.isEncrypted = if let key, !key.isEmpty { true } else { false }
        
        // Set the writer’s onUpdate closure to call the `onUpdate`
        // method, publishing an update notification on changes.
        writer.onUpdate = {
            [unowned self] connection in self.onUpdate(connection)
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
    public func resetKey(to key: String?) throws {
        try self.writer.resetKey(to: key)
        try self.reader.setKey(key)
        
        self.isEncrypted = if let key, !key.isEmpty { true } else { false }
    }
}

extension SQLCipher: Equatable {
    public static func ==(lhs: SQLCipher, rhs: SQLCipher) -> Bool {
        return lhs === rhs
    }
}

// MARK: - Reading, Writing
extension SQLCipher {
    /// Provides access to the writer connection for performing write operations.
    ///
    /// - Parameter block: A closure that takes the writer `Connection` and performs
    ///   operations on the database. This closure may throw errors.
    /// - Throws: Rethrows any error that the block throws.
    public func write<T>(_ block: (Database) throws -> T) rethrows -> T {
        return try writer.performTask(block)
    }
    
    /// Provides access to the reader connection for performing read operations.
    ///
    /// - Parameter block: A closure that takes the reader `Connection` and performs
    ///   operations on the database. This closure may throw errors.
    /// - Throws: Rethrows any error that the block throws.
    public func read<T>(_ block: (Database) throws -> T) rethrows -> T {
        return try reader.performTask(block)
    }
    
    /// Provides asynchronous access to the writer connection for performing write operations.
    ///
    /// - Parameter block: An asynchronous closure that takes the writer `Connection` and performs
    ///   operations on the database. This closure may throw errors.
    /// - Throws: Rethrows any error that the block throws.
    /// - Returns: The result of the block's execution.
    public func write<T>(_ block: (Database) async throws -> T) async rethrows -> T {
        return try await writer.performTask(block)
    }

    /// Provides asynchronous access to the reader connection for performing read operations.
    ///
    /// - Parameter block: An asynchronous closure that takes the reader `Connection` and performs
    ///   operations on the database. This closure may throw errors.
    /// - Throws: Rethrows any error that the block throws.
    /// - Returns: The result of the block's execution.
    public func read<T>(_ block: (Database) async throws -> T) async rethrows -> T {
        return try await reader.performTask(block)
    }
}
    
// MARK: - Observation
extension SQLCipher {
    /// Called when changes are commited to the `writer` database.
    /// - Parameter connection: the `writer` connection
    /// - Returns: `SQLITE_OK` to allow the commit to occur
    private func onUpdate(_ connection: Connection) -> SQLErrorCode {
        didUpdate.send(())
        return SQLITE_OK
    }
}

// MARK: - Simplified DB Access

/// Convenience functions that forward operations to the `.writer` connection.
/// These methods allow SQL commands to be executed within the context of the
/// writable database connection.
///
/// Note: For greater efficiency, use `SQLCipher`'s `.read()` and `.write())`
/// closure-based APIs to have queries routed appropriately..
extension SQLCipher: Database {
    /// Begins a transaction on the `.writer` connection.
    ///
    /// - Throws: An error if the transaction cannot be started.
    ///
    /// - See Also: `SQLCipher.write(_:)`, `Connection.begin()`
    public func begin() throws {
        try writer.begin()
    }
    
    /// Commits the current transaction on the `.writer` connection.
    ///
    /// - Throws: An error if the commit fails.
    ///
    /// - See Also: `SQLCipher.write(_:)`, `Connection.commit()`
    public func commit() throws {
        try writer.commit()
    }
    
    /// Rolls back the current transaction on the `.writer` connection.
    ///
    /// - Throws: An error if the rollback fails.
    ///
    /// - See Also: `SQLCipher.write(_:)`, `Connection.rollback()`
    public func rollback() throws {
        try writer.rollback()
    }
    
    /// Executes a SQL command without returning any rows.
    ///
    /// - Parameter sql: The SQL command to execute.
    /// - Throws: An error if the command fails.
    ///
    /// - See Also: `SQLCipher.write(_:)`, `Connection.exec(_:)`
    public func exec(_ sql: String) throws {
        try writer.exec(sql)
    }
    
    /// Executes a query on the `.writer` connection.
    ///
    /// - Parameter sql: The SQL query to execute.
    /// - Returns: An array of `Row` objects containing the results.
    /// - Throws: An error if the query fails.
    ///
    /// - See Also: `SQLCipher.write(_:)`, `Connection.execute(_:)`
    public func execute(_ sql: String) throws -> [SQLRow] {
        try writer.execute(sql)
    }
    
    /// Executes a query on the `.writer` connection with positional bindings.
    ///
    /// - Parameters:
    ///   - sql: The SQL query to execute.
    ///   - values: An array of `Value` objects for positional binding.
    /// - Returns: An array of `Row` objects containing the results.
    /// - Throws: An error if the query fails.
    ///
    /// - See Also: `SQLCipher.write(_:)`, `Connection.execute(_:with:)`
    public func execute(_ sql: String, _ values: [SQLValue]) throws -> [SQLRow] {
        try writer.execute(sql, values)
    }
    
    /// Executes a query on the `.writer` connection with named bindings.
    ///
    /// - Parameters:
    ///   - sql: The SQL query to execute.
    ///   - namedValues: A dictionary mapping placeholder names to `Value` objects.
    /// - Returns: An array of `Row` objects containing the results.
    /// - Throws: An error if the query fails.
    ///
    /// - See Also: `SQLCipher.write(_:)`, `Connection.execute(_:with:)`
    public func execute(_ sql: String, _ namedValues: [String: SQLValue]) throws -> [SQLRow] {
        try writer.execute(sql, namedValues)
    }
}
