//
//  SQLCipher.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 10/15/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import OSLog
import Combine
import Foundation

@_exported import CSQLCipher

/// A class for managing encrypted SQLite database connections using
/// SQLCipher. It provides separate read and write connections with
/// appropriate queue handling for concurrent reads and serialized
/// writes.
public final class SQLCipher {
    /// The file path to the SQLite database.
    public let path: String
    
    /// Separate connections for read and write operations.
    public let reader, writer: SQLConnection
    
    /// A subject that publishes an event whenever the database is
    /// updated, allowing observers to be notified of changes.
    private let didUpdate = CurrentValueSubject<Void, Never>(())
    
    /// Package-internal logger for SQLCipher operations.
    internal static let log = Logger(
        subsystem: "com.dimension-north.SQLCipher",
        category: "SQLCipher"
    )

    /// `true` if the receiver is an encrypted database, `false` otherwise
    public var isEncrypted: Bool {
        writer.isEncrypted
    }
    
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
        self.reader = try SQLConnection(path: path, key: key, role: .reader)
        self.writer = try SQLConnection(path: path, key: key, role: .writer)
        
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
        try self.writer.resetKey(key)
        try self.reader.resetKey(key)
    }
}

extension SQLCipher: Equatable {
    public static func ==(lhs: SQLCipher, rhs: SQLCipher) -> Bool {
        return lhs === rhs
    }
}

// MARK: - Observation
extension SQLCipher {
    /// Called when changes are commited to the `writer` database.
    /// - Parameter connection: the `writer` connection
    /// - Returns: `SQLITE_OK` to allow the commit to occur
    private func onUpdate(_ connection: SQLConnection) -> SQLErrorCode {
        didUpdate.send(())
        return SQLITE_OK
    }
}

//extension SQLCipher {
//    /// Provides access to the writer connection for performing write operations.
//    ///
//    /// - Parameter block: A closure that takes the writer `Connection` and performs
//    ///   operations on the database. This closure may throw errors.
//    /// - Throws: Rethrows any error that the block throws.
//    public func write<T>(_ block: (SQLConnection) throws -> T) rethrows -> T {
//        return try block(writer)
//    }
//    
//    /// Provides access to the reader connection for performing read operations.
//    ///
//    /// - Parameter block: A closure that takes the reader `Connection` and performs
//    ///   operations on the database. This closure may throw errors.
//    /// - Throws: Rethrows any error that the block throws.
//    public func read<T>(_ block: (SQLConnection) throws -> T) rethrows -> T {
//        return try block(reader)
//    }
//    
//    /// Provides asynchronous access to the writer connection for performing write operations.
//    ///
//    /// - Parameter block: An asynchronous closure that takes the writer `Connection` and performs
//    ///   operations on the database. This closure may throw errors.
//    /// - Throws: Rethrows any error that the block throws.
//    /// - Returns: The result of the block's execution.
//    public func write<T>(_ block: (SQLConnection) async throws -> T) async rethrows -> T {
//        return try await block(writer)
//    }
//
//    /// Provides asynchronous access to the reader connection for performing read operations.
//    ///
//    /// - Parameter block: An asynchronous closure that takes the reader `Connection` and performs
//    ///   operations on the database. This closure may throw errors.
//    /// - Throws: Rethrows any error that the block throws.
//    /// - Returns: The result of the block's execution.
//    public func read<T>(_ block: (SQLConnection) async throws -> T) async rethrows -> T {
//        return try await block(reader)
//    }
//}
