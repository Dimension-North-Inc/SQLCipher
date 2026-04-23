//
//  ChangeTracker.swift
//  SQLCipher
//
//  Created by Kimi on 4/23/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import Foundation

/// Lightweight accumulator for table names changed during a transaction.
///
/// `ChangeTracker` is driven by `sqlite3_update_hook` and flushed by the
/// commit/rollback hooks on a single `SQLConnection`.
package final class ChangeTracker: @unchecked Sendable {
    private var tables: Set<String> = []
    
    /// Records that a row in the given table was modified.
    package func record(table: String) {
        tables.insert(table)
    }
    
    /// Returns all accumulated table names and clears the accumulator.
    package func flush() -> Set<String> {
        let result = tables
        tables.removeAll()
        return result
    }
}
