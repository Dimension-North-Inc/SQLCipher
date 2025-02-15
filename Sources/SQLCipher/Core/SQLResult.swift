//
//  SQLResult.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 1/31/25.
//  Copyright © 2025 Dimension North Inc. All rights reserved.
//

import Foundation

/// Encapsulates the result of an SQL execution, including rows and metadata.
public struct SQLResult {
    /// The rows returned from a `SELECT` query.
    public let rows: [SQLRow]

    /// The number of rows affected by an `UPDATE`, `DELETE`, or `INSERT`.
    public let affectedRows: Int32

    /// The last inserted row ID (relevant for `INSERT` operations with auto-increment tables).
    public let lastInsertedRowID: Int64?

    /// Creates a `SQLResult` with precomputed rows and metadata.
    ///
    /// - Parameters:
    ///   - rows: The result set (if applicable).
    ///   - affectedRows: The number of rows affected by an `UPDATE`, `DELETE`, or `INSERT`.
    ///   - lastInsertedRowID: The last inserted row ID for auto-increment tables.
    init(rows: [SQLRow], affectedRows: Int32, lastInsertedRowID: Int64?) {
        self.rows = rows
        self.affectedRows = affectedRows
        self.lastInsertedRowID = lastInsertedRowID
    }
}

extension SQLResult: RandomAccessCollection {
    public var endIndex: Int { rows.endIndex }
    public var startIndex: Int { rows.startIndex }

    public subscript(position: Int) -> SQLRow {
        rows[position]
    }
}
