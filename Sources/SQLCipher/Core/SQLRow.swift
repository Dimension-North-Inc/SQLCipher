//
//  SQLRow.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 1/31/25.
//  Copyright © 2025 Dimension North Inc. All rights reserved.
//

import Foundation

@dynamicMemberLookup
public struct SQLRow {
    var values: [String: SQLValue] = [:]
    
    public init() {}
    
    /// Creates a `SQLRow` from a SQLite statement pointer.
    ///
    /// - Parameter statement: The SQLite statement pointer (OpaquePointer).
    /// - Note: This reads all columns from the current row in the SQLite result set.
    public init(statement: OpaquePointer) {
        for index in 0..<sqlite3_column_count(statement) {
            let columnName = String(cString: sqlite3_column_name(statement, index))
            values[columnName] = SQLValue(stmt: statement, col: index)
        }
    }

    /// Provides  access to values stored in the row.
    ///
    /// - Parameter key: The key associated with the desired value.
    /// - Returns: The value converted to `T`, or `nil` if conversion fails.
    public subscript(key: String) -> SQLValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// Provides typed access to values stored in the row.
    ///
    /// - Parameter key: The key associated with the desired value.
    /// - Returns: The value converted to `T`, or `nil` if conversion fails.
    public subscript<T: SQLValueRepresentable>(key: String) -> T? {
        get {
            guard let sqliteVal = values[key] else { return nil }
            return T(sqliteValue: sqliteVal)
        }
        set {
            if let newValue = newValue {
                values[key] = newValue.sqliteValue
            } else {
                values[key] = .null
            }
        }
    }
    
    /// Enables dot-access using `@dynamicMemberLookup`
    public subscript<T: SQLValueRepresentable>(dynamicMember member: String) -> T? {
        get { self[member] }
        set { self[member] = newValue }
    }

}
