//
//  Errors.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 10/15/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import CSQLCipher
import Foundation
import OSLog

/// A detailed error type that provides both the SQLite error code and a human-readable message.
public enum SQLiteError: Error, CustomStringConvertible {
    /// A general error produced by the SQLite engine.
    case general(code: Int32, message: String)

    public var description: String {
        switch self {
        case .general(let code, let message):
            return "SQLite error code \(code): \(message)"
        }
    }
}

/// Type alias representing an SQLite error code.
public typealias SQLErrorCode = Int32

/// Validates the result code of an SQLite operation, throwing a detailed
/// `SQLiteError` if the code does not indicate success.
///
/// This function simplifies error checking by capturing the human-readable
/// error message directly from the database connection if a failure occurs.
///
/// - Parameters:
///   - code: The result code of an SQLite operation.
///   - db: The database handle (`sqlite3*`) on which the operation was performed.
/// - Throws: A `SQLiteError` containing the code and detailed message if the operation failed.
public func checked(_ code: SQLErrorCode, on db: OpaquePointer?) throws {
    guard code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE else {
        // Get the detailed, human-readable error message from SQLite.
        let message = String(cString: sqlite3_errmsg(db))
        
        // Create our new, descriptive error.
        let error = SQLiteError.general(code: code, message: message)
        
        // Log the rich error message.
        log.error("checked(_:on:) throwing: \(error.description)")
        
        throw error
    }
}

/// Package-internal logger for SQLCipher operations.
private let log = Logger(
    subsystem: "com.dimension-north.SQLCipher",
    category: "Error"
)
