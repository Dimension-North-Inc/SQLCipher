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
public final class SQLCipher: @unchecked Sendable {
    /// The file path to the SQLite database.
    public let path: String
    
    /// Separate connections for read and write operations.
    public private(set) var reader, writer: SQLConnection
    
    /// A subject that publishes the set of changed table names whenever the
    /// database is updated, allowing observers to be notified of changes.
    package let didUpdate = CurrentValueSubject<Set<String>, Never>([])
    
    /// The current sync configuration, if any.
    package var syncConfiguration: SyncConfiguration?
    
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
        // method, publishing an update notification with changed table names.
        writer.onCommitted = {
            [unowned self] tables in self.onUpdate(tables)
        }
    }
    
    /// Resets the database encryption with a new encryption key.
    ///
    /// This method symmetrically supports all encryption state transitions:
    /// - Encrypted → Encrypted (different key): fast in-place rekey
    /// - Plaintext → Encrypted: `sqlcipher_export` migration
    /// - Encrypted → Plaintext: `sqlcipher_export` migration
    /// - Plaintext → Plaintext: no-op
    ///
    /// - Parameter key: The new encryption key. Pass `nil` or an empty
    ///   string for a plaintext database.
    /// - Throws: An `SQLiteError` if the operation fails.
    public func resetKey(to key: String?) throws {
        let newKey = key ?? ""
        let targetEncrypted = !newKey.isEmpty
        let currentlyEncrypted = self.isEncrypted
        
        // No change in encryption state or key
        if currentlyEncrypted == targetEncrypted {
            if targetEncrypted {
                // Fast path: rekey in-place
                try self.writer.resetKey(key)
                try self.reader.resetKey(key)
            }
            return
        }
        
        // In-memory databases don't support file-based migration
        guard path != ":memory:" else {
            throw SQLiteError.general(
                code: SQLITE_MISUSE,
                message: "In-memory databases do not support encryption state migration. "
                       + "Create the database with the desired key from the start."
            )
        }
        
        // Migration path: sqlcipher_export to a temp file, then swap
        try migrateEncryptionState(to: newKey)
    }
    
    private func migrateEncryptionState(to newKey: String) throws {
        let tempPath = path + ".migration-\(UUID().uuidString)"
        let escapedTemp = tempPath.replacingOccurrences(of: "'", with: "''")
        let escapedKey = newKey.replacingOccurrences(of: "'", with: "''")
        let attachKey = newKey.isEmpty ? "''" : "'\(escapedKey)'"
        
        // Export current database to temp file with target encryption state
        try writer.exec("ATTACH DATABASE '\(escapedTemp)' AS migration_db KEY \(attachKey);")
        try writer.exec("SELECT sqlcipher_export('migration_db');")
        try writer.exec("DETACH DATABASE migration_db;")
        
        // Close both connections so the file can be swapped
        sqlite3_close_v2(writer.db)
        sqlite3_close_v2(reader.db)
        
        // Atomic swap: original → backup, temp → original, delete backup
        let fm = FileManager.default
        let backupPath = path + ".backup-\(UUID().uuidString)"
        
        do {
            try fm.moveItem(atPath: path, toPath: backupPath)
            try fm.moveItem(atPath: tempPath, toPath: path)
            try fm.removeItem(atPath: backupPath)
            
            // Reopen both connections with the new key state
            self.writer = try SQLConnection(path: path, key: newKey.isEmpty ? nil : newKey, role: .writer)
            self.reader = try SQLConnection(path: path, key: newKey.isEmpty ? nil : newKey, role: .reader)
            
            // Reinstall the commit hook on the new writer
            self.writer.onCommitted = { [unowned self] tables in self.onUpdate(tables) }
        } catch {
            // Attempt recovery if the original was moved to backup
            if fm.fileExists(atPath: backupPath) && !fm.fileExists(atPath: path) {
                try? fm.moveItem(atPath: backupPath, toPath: path)
            }
            throw error
        }
    }
}

extension SQLCipher: Equatable {
    public static func ==(lhs: SQLCipher, rhs: SQLCipher) -> Bool {
        return lhs === rhs
    }
}

// MARK: - Observation
extension SQLCipher {
    /// Called when changes are committed to the `writer` database.
    /// - Parameter tables: the set of table names that changed in this transaction
    /// - Returns: `SQLITE_OK` to allow the commit to occur
    private func onUpdate(_ tables: Set<String>) -> SQLErrorCode {
        didUpdate.send(tables)
        return SQLITE_OK
    }
}
