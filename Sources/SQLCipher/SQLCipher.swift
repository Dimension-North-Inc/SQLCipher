//
//  SQLCipher.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 10/15/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import Foundation
import Combine
import OSLog

@_exported import CSQLCipher

public final class SQLCipher {
    public let path: String
    
    private var reader, writer: Connection
    private let didUpdate = PassthroughSubject<Void, Never>()
    
    // Package-internal logger for SQLCipher operations
    internal static let log = Logger(subsystem: "com.dimension-north.SQLCipher", category: "SQLCipher")

    public init(path: String, key: String? = nil) throws {
        SQLCipher.log.info("connecting to: \(path)")
        self.path = path
        
        self.reader = try Connection(path: path, key: key, role: .reader)
        self.writer = try Connection(path: path, key: key, role: .writer)
        
        writer.onUpdate = {
            [unowned self] connection in self.onUpdate(connection)
        }
    }
    
    /// Checks if the database file at `path` is empty.
    ///
    /// This method reports `true` if the database file exists and is 0 bytes
    /// in size, which typically means it has no associated schema.
    ///
    /// - Returns: `true` if the file exists but has a size of 0 bytes; otherwise, `false`.
    public func isEmpty() -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let fileSize = attributes[.size] as? UInt64 {
                return fileSize == 0
            } else {
                SQLCipher.log.error("Unable to retrieve file size for path: \(self.path, privacy: .public)")
                return false
            }
        } catch {
            SQLCipher.log.error("Failed to access file at path: \(self.path, privacy: .public) with error: \(error.localizedDescription, privacy: .public)")
            return false
        }
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
}
    
// MARK: - Observation
extension SQLCipher {
    
    /// Called when changes are commited to the `writer` database.
    /// - Parameter connection: the `writer` connection
    /// - Returns: `SQLITE_OK` to allow the commit to occur
    func onUpdate(_ connection: Connection) -> SQLiteErrorCode {
        didUpdate.send()
        return SQLITE_OK
    }

    /// Returns a publisher that performs a read operation each time the underlying database changes.
    /// Read operations must be pure - they can not update the database and are, in fact, prevented
    /// from doing so.
    ///
    /// - Parameter block: A closure that takes the reader `Connection` and performs
    ///   operations on the database. This closure may throw errors.
    /// - Returns: An `AnyPublisher` that emits the result of the closure's execution each time `didUpdate` is triggered.
    public func observe<T>(_ block: @escaping (Database) throws -> T) -> AnyPublisher<T, Never> {
        didUpdate
            .map { [weak self] _ -> T? in
                guard let self = self else { return nil }
                do {
                    return try self.read(block)
                } catch {
                    return nil
                }
            }
            .compactMap { $0 }  // Filter out nil values, if an error occurred or `self` was nil
            .eraseToAnyPublisher()
    }
}
