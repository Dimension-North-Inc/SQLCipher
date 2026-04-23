//
//  SQLCipherStore+Sync.swift
//  SQLCipher
//
//  Created by Kimi on 4/23/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import Foundation

extension SQLCipherStore {
    /// Enables CloudKit sync for this store by adding the `stored_substates`
    /// table to the sync configuration with the `.substateAware` strategy.
    ///
    /// Call this after initializing the store and after calling `db.configureSync(...)`.
    public func enableSync() {
        db.addSyncedTable("stored_substates", strategy: .substateAware)
    }
}
