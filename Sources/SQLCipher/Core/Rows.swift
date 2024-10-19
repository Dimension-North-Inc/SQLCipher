//
//  Rows.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 10/15/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import CSQLCipher
import Foundation

/// Represents a single row in a SQLite query result, mapping column names
/// to their respective values.
///
/// This struct provides subscript access by column name, returning the
/// associated `Value` for each column in the row.
public struct SQLRow {
    private var values: [String: SQLValue]
    
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
            values[columnName] = SQLValue(stmt: statement, col: index)
        }
    }
    
    /// Accesses the `Value` associated with the specified column name.
    ///
    /// - Parameter key: The column name.
    /// - Returns: The `Value` for the column, or `nil` if the column name
    ///   does not exist in the row.
    public subscript(key: String) -> SQLValue? {
        return values[key]
    }
}

/// Represents a value that can be stored in a SQLite database,
/// encapsulating the common SQLite data types.
public enum SQLValue: Hashable {
    case number(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
        
    // synthetic IN statement support
    indirect case array([SQLValue])
    
    public var numberValue: Int64? {
        if case let .number(value) = self {
            return value
        } else {
            return nil
        }
    }
    
    public var realValue: Double? {
        if case let .real(value) = self {
            return value
        } else {
            return nil
        }
    }
    
    public var textValue: String? {
        if case let .text(value) = self {
            return value
        } else {
            return nil
        }
    }
    
    public  var blobValue: Data? {
        if case let .blob(value) = self {
            return value
        } else {
            return nil
        }
    }
}

extension SQLValue: CustomStringConvertible {
    // CustomStringConvertible conformance
    public var description: String {
        switch self {
        case .number(let value):
            return "number(\(value))"

        case .real(let value):
            return "real(\(value))"

        case .text(let value):
            return "text(\(value))"

        case .blob(let value):
            return "blob(\(value.count) bytes)"

        case .array(let value):
            return "array(\(value))"

        case .null:
            return "null"
        }
    }
}


extension SQLValue {
    public static func optional<T>(_ value: T?) -> Self where T: OptionalType, T.Wrapped == SQLValue {
        return value?.wrappedValue ?? .null
    }

    public func optionalValue<T: OptionalType>() -> T? where T.Wrapped == SQLValue {
        if case let wrapped as T = self { return wrapped }
        return nil
    }
    
    public static func encoded<T: Codable>(_ codable: T?) throws -> Self {
        guard let codable else { return .null }
        return .blob(try JSONEncoder().encode(codable))
    }

    public func encodedValue<T: Codable>(as type: T.Type) -> T? {
        if case let .blob(data) = self {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        return nil
    }

    public static func secureEncoded<T: NSObject & NSSecureCoding>(_ value: T?) throws -> Self {
        guard let value else { return .null }
        let data = try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
        return .blob(data)
    }

    public func secureEncodedValue<T: NSObject & NSSecureCoding>(as type: T.Type) -> T? {
        if case let .blob(data) = self {
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: type, from: data)
        }
        return nil
    }

    public static func bool(_ value: Bool?) -> Self {
        guard let value else { return .null }
        return .number(value ? 1 : 0)
    }

    public var boolValue: Bool? {
        if case let .number(value) = self {
            return value == 1
        }
        return nil
    }

    public static func date(_ date: Date?) -> Self {
        guard let date else { return .null }
        return .text(date.formatted(.iso8601))
    }

    public var dateValue: Date? {
        if case let .text(value) = self {
            return try? Date(value, strategy: .iso8601)
        }
        return nil
    }
    
    public static func uuid(_ uuid: UUID?) -> Self {
        guard let uuid else { return .null }
        return .text(uuid.uuidString)
    }

    public var uuidValue: UUID? {
        if case let .text(value) = self {
            return UUID(uuidString: value)
        }
        return nil
    }
}

extension SQLValue {
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
            self = .number(sqlite3_column_int64(stmt, col))
        case SQLITE_FLOAT:
            self = .real(sqlite3_column_double(stmt, col))
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
        case .number(let intValue):
            result = sqlite3_bind_int64(stmt, idx, intValue)
        case .real(let doubleValue):
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
            
        case .array:
            throw SQLiteError(misuse: "unexpected array binding in expression")
        }
        
        if result != SQLITE_OK {
            throw SQLiteError(code: result)
        }
    }
}

/// A constant used to inform SQLite that it should make a copy of the text
/// or blob data when binding. This is necessary for transient data that will
/// not persist beyond the scope of the SQLite statement execution.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
