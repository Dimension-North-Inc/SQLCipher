//
//  Errors.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 10/15/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import CSQLCipher
import Foundation

/// Represents an error occurring during SQLite operations, providing
/// both an error code and description.
public struct SQLiteError: Error {
    /// The SQLite error code associated with the error.
    public var code: SQLiteErrorCode
    
    /// A textual description of the error.
    public var description: String

    /// Initializes a general SQLite error with a custom description.
    /// - Parameter description: A message describing the error.
    public init(error description: String) {
        self.code = SQLITE_ERROR
        self.description = description
    }
    
    /// Initializes an error specific to SQLite misuse with a custom
    /// description.
    /// - Parameter description: A message describing the error.
    public init(misuse description: String) {
        self.code = SQLITE_MISUSE
        self.description = description
    }

    /// Initializes an SQLite error with a given code and an optional
    /// custom description.
    ///
    /// If no description is provided, it will use the default SQLite
    /// error message for the provided code.
    ///
    /// - Parameters:
    ///   - code: The SQLite error code associated with the error.
    ///   - description: An optional message describing the error.
    public init(code: SQLiteErrorCode, description: String? = nil) {
        self.code = code
        self.description = description ?? String(cString: sqlite3_errstr(code))
    }
}

/// Type alias representing an SQLite error code.
public typealias SQLiteErrorCode = Int32

/// Validates the result code of an SQLite operation, throwing an
/// `SQLiteError` if the code does not indicate success.
///
/// This function simplifies error checking by allowing a single
/// line to validate an SQLite function call and throw an appropriate
/// error if it fails.
///
/// - Parameter code: The result code of an SQLite operation.
/// - Throws: An `SQLiteError` if the code is not `SQLITE_OK`,
///   `SQLITE_ROW`, or `SQLITE_DONE`.
/// - Returns: The result code if it represents success.
@discardableResult
public func checked(_ code: SQLiteErrorCode) throws -> SQLiteErrorCode {
    guard code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE else {
        throw SQLiteError(code: code)
    }
    return code
}
