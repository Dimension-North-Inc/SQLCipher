//
//  Value.swift
//  CSQLCipher
//
//  Created by Mark Onyschuk on 10/15/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import CSQLCipher
import Foundation

/// Represents a value that can be stored in a SQLite database,
/// encapsulating the common SQLite data types.
public enum Value {
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
    
    /// Initializes a `Value` from a column in a SQLite statement.
    ///
    /// This initializer uses the column data type of the specified column
    /// in the SQLite statement and creates a `Value` instance representing
    /// the data in that column.
    ///
    /// - Parameters:
    ///   - stmt: The SQLite statement pointer.
    ///   - col: The column index to read from.
    init(stmt: OpaquePointer, col: Int32) {
        switch sqlite3_column_type(stmt, col) {
        case SQLITE_INTEGER:
            self = .integer(sqlite3_column_int64(stmt, col))
        case SQLITE_FLOAT:
            self = .double(sqlite3_column_double(stmt, col))
        case SQLITE_TEXT:
            if let textPointer = sqlite3_column_text(stmt, col) {
                self = .text(String(cString: textPointer))
            } else {
                self = .null
            }
        case SQLITE_BLOB:
            if let blobPointer = sqlite3_column_blob(stmt, col) {
                let length = sqlite3_column_bytes(stmt, col)
                self = .blob(Data(bytes: blobPointer, count: Int(length)))
            } else {
                self = .null
            }
        default:
            self = .null
        }
    }
    
    /// Binds this `Value` to a SQLite statement at the specified index.
    ///
    /// This method converts the `Value` to a suitable SQLite-compatible
    /// format and binds it to the SQLite statement at the given index.
    ///
    /// - Parameters:
    ///   - stmt: The SQLite statement pointer.
    ///   - idx: The 1-based index at which to bind the value.
    /// - Throws: An `SQLiteError` if the binding operation fails.
    func bind(to stmt: OpaquePointer?, at idx: Int32) throws {
        let result: Int32
        switch self {
        case .integer(let intValue):
            result = sqlite3_bind_int64(stmt, idx, intValue)
        case .double(let doubleValue):
            result = sqlite3_bind_double(stmt, idx, doubleValue)
        case .text(let stringValue):
            result = sqlite3_bind_text(stmt, idx, stringValue, -1, SQLITE_TRANSIENT)
        case .blob(let data):
            result = data.withUnsafeBytes {
                bytes in sqlite3_bind_blob(
                    stmt, idx, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT
                )
            }
        case .null:
            result = sqlite3_bind_null(stmt, idx)
        }
        
        if result != SQLITE_OK {
            throw SQLiteError(code: result)
        }
    }
}

extension Value: CustomStringConvertible {
    // CustomStringConvertible conformance
    public var description: String {
        switch self {
        case .integer(let intValue):
            return "integer(\(intValue))"
        case .double(let doubleValue):
            return "double(\(doubleValue))"
        case .text(let textValue):
            return "text(\(textValue))"
        case .blob(let data):
            return "blob(\(data.count) bytes)"
        case .null:
            return "null"
        }
    }
}


/// Represents a single row in a SQLite query result, mapping column names
/// to their respective values.
///
/// This struct provides subscript access by column name, returning the
/// associated `Value` for each column in the row.
public struct Row {
    private var values: [String: Value]
    
    /// Initializes a `Row` by reading all columns from a SQLite statement.
    ///
    /// This initializer iterates through all columns in the specified
    /// SQLite statement and creates a dictionary mapping column names
    /// to `Value` instances representing the column's data.
    ///
    /// - Parameter statement: The SQLite statement pointer.
    init(statement: OpaquePointer) {
        self.values = [:]
        for index in 0..<sqlite3_column_count(statement) {
            let columnName = String(cString: sqlite3_column_name(statement, index))
            values[columnName] = Value(stmt: statement, col: index)
        }
    }
    
    /// Accesses the `Value` associated with the specified column name.
    ///
    /// - Parameter key: The column name.
    /// - Returns: The `Value` for the column, or `nil` if the column name
    ///   does not exist in the row.
    subscript(key: String) -> Value? {
        return values[key]
    }
}

/// A constant used to inform SQLite that it should make a copy of the text
/// or blob data when binding. This is necessary for transient data that will
/// not persist beyond the scope of the SQLite statement execution.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
