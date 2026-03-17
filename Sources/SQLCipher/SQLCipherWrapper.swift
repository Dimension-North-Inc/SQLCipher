//
//  SQLCipherDocument.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 03/17/26.
//

import Foundation

/// Manages the on-disk representation of a document's encrypted SQLite database for a `FileDocument`-based app.
///
/// `SQLCipherDocument` is responsible for:
/// - Creating a unique temporary path in the system temporary directory
/// - Writing the provided `FileWrapper` (regular file or directory package) to that path
/// - Determining the correct location of the SQLite database file
/// - Initializing a `SQLCipher` connection to that database
/// - Providing access to the `SQLCipher` instance and the temporary root URL
/// - Flushing changes before saving
/// - Cleaning up resources when no longer needed
///
/// Supports two document formats:
/// - **Single-file format**: The document is just the SQLite database file
///   → database is located directly at the temp path
/// - **Package format** (directory): Contains multiple files/folders
///   → database is expected at the conventional name `"db.sqlite"` inside the directory
///
/// If the expected database file is missing in package mode, `SQLCipher` will create an empty one.
public struct SQLCipherWrapper {
    
    /// The low-level encrypted SQLite connection manager.
    /// Use this directly or wrap it with higher-level logic (e.g. SQLCipherStore) as needed.
    public let db: SQLCipher
    
    /// The root URL where the document contents (file or directory package) reside on disk.
    /// Use this URL with `FileWrapper(url:)` to create the save snapshot.
    public let tempURL: URL
    
    /// Initializes a `SQLCipherDocument` by writing the given `FileWrapper` to a fresh temporary location
    /// and connecting to the appropriate SQLite database file.
    ///
    /// - Parameters:
    ///   - wrapper: The `FileWrapper` representing the document contents.
    ///     - New documents: pass an empty wrapper (regular file or directory)
    ///     - Existing documents: pass `configuration.file`
    ///   - key: Optional encryption key for SQLCipher. Pass `nil` for unencrypted.
    /// - Throws: If writing the wrapper fails or `SQLCipher` cannot be initialized.
    public init(from wrapper: FileWrapper, key: String? = nil) throws {
        // Generate a unique path — nothing is created yet
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        
        // Write wrapper contents to tempPath.
        //   • regular file  → file created at tempPath
        //   • directory     → directory created at tempPath with contents inside
        try wrapper.write(
            to: tempPath,
            options: .atomic,
            originalContentsURL: nil
        )
        
        let dbURL: URL
        
        if wrapper.isRegularFile {
            // Single-file format: database is the file written directly at tempPath
            dbURL = tempPath
        } else {
            // Package format: database is at conventional name inside the directory
            dbURL = tempPath.appendingPathComponent("db.sqlite")
            
            // Note: If "db.sqlite" is missing (new doc / malformed package),
            // SQLCipher will create an empty database when initialized below.
        }
        
        // Connect to the database (creates it if it doesn't exist)
        self.db = try SQLCipher(path: dbURL.path, key: key)
        self.tempURL = tempPath
    }
    
    /// Ensures all pending changes are flushed to the main database file before saving.
    ///
    /// Call this before creating a `FileWrapper` representation for save/autosave.
    /// Uses `PRAGMA wal_checkpoint(FULL)` for a thorough, safe checkpoint.
    /// Adjust the mode if your workload prefers a different trade-off (e.g. PASSIVE, RESTART).
    public func flush() throws {
        try db.writer.execute("PRAGMA wal_checkpoint(FULL);")
    }
    
    /// The current on-disk state as a FileWrapper, ready for use in `FileDocument.fileWrapper(configuration:)`.
    ///
    /// This property guarantees that all pending changes are flushed before constructing the wrapper,
    /// ensuring the snapshot is consistent and up-to-date.
    public var wrapper: FileWrapper {
        get throws {
            try flush()
            return try FileWrapper(url: tempURL, options: [])
        }
    }
    
    /// Closes database connections and deletes the temporary directory.
    ///
    /// Call this in the `deinit` of your `FileDocument` type to release resources.
    public func cleanup() {
        do {
            try FileManager.default.removeItem(at: tempURL)
        } catch {
            // Log failure but don't crash — cleanup errors are non-fatal
            SQLCipher.log.warning("Failed to remove temp directory at \(tempURL.path): \(error)")
        }
    }
}
