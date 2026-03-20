//
//  SQLCipherWrapper.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 03/17/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import Foundation

/// Manages the on-disk representation of an encrypted SQLite database.
public final class SQLCipherWrapper: @unchecked Sendable {

    // MARK: - Public API
    
    /// The low-level encrypted SQLite connection manager.
    public let db: SQLCipher
    
    /// The root URL where wrapper contents (file or directory package) reside on disk.
    public let url: URL

    /// Describes the on-disk location and creation strategy for the database.
    public enum Location {
        /// The wrapper will operate within a unique temporary directory. This is the
        /// standard choice for SwiftUI `FileDocument`-based apps.
        case temporary
        
        /// The wrapper will operate at a fixed, user-specified URL.
        /// - Parameters:
        ///   - at: The permanent URL for the database file or package.
        ///   - reinstall: If `true`, any existing data at the URL will be deleted and
        ///                replaced with the provided `content`. Defaults to `false`,
        ///                which safely opens the existing data or creates it if it doesn't exist.
        case fixed(_ at: URL, reinstall: Bool = false)
    }

    /// Initializes a `SQLCipherWrapper` for document or non-document based applications.
    ///
    /// The structure of the database (single file vs. package) is always inferred from `content.isDirectory`.
    ///
    /// - Parameters:
    ///   - location: The location and creation strategy.
    ///   - content: The `FileWrapper` that defines the structure and initial state of the database.
    ///   - key: Optional encryption key for SQLCipher. Pass `nil` for an unencrypted database.
    /// - Throws: A `CocoaError` for any file system failures during initialization.
    public init(
        location: Location,
        content: FileWrapper,
        key: String? = nil
    ) throws {
        
        let fileManager = FileManager.default
        self.isPackage = content.isDirectory
        
        // 1. Determine URL, ownership, and set up the file system state.
        switch location {
        case .temporary:
            self.url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            self.isTemporary = true
            // In the temporary case, the parent directory is guaranteed to exist.
            try content.write(to: self.url, options: .atomic, originalContentsURL: nil)

        case .fixed(let url, let reinstall):
            self.url = url
            self.isTemporary = false
            
            let fileExists = fileManager.fileExists(atPath: self.url.path)
            let shouldWrite = reinstall || !fileExists
            
            if shouldWrite {
                // *** FIX: Ensure the parent directory exists before writing. ***
                // This prevents errors when the destination is in a subdirectory that
                // has not been created yet (e.g., Application Support).
                let parentDirectory = self.url.deletingLastPathComponent()
                try fileManager.createDirectory(
                    at: parentDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                
                if reinstall && fileExists {
                    try fileManager.removeItem(at: self.url)
                }
                
                try content.write(to: self.url, options: .atomic, originalContentsURL: nil)
            }
            // If `reinstall` is false and the file exists, we do nothing and proceed to open it.
        }
        
        // 2. Connect to the database.
        let dbURL = self.isPackage ? self.url.appendingPathComponent("db.sqlite") : self.url
        self.db = try SQLCipher(path: dbURL.path, key: key)
    }
    
    public func flush() throws {
        try db.writer.execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }
    
    public var wrapper: FileWrapper {
        get throws {
            try flush()
            return try FileWrapper(url: url, options: [])
        }
    }
    
    deinit {
        if isTemporary {
            do { try FileManager.default.removeItem(at: url) }
            catch { print("Warning: Failed to remove temp directory at \(url.path): \(error)") }
        }
    }
    
    // MARK: - Private Properties
    private let isTemporary: Bool
    private let isPackage: Bool
}
