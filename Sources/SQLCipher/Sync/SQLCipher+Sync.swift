//
//  SQLCipher+Sync.swift
//  SQLCipher
//
//  Created by Kimi on 4/23/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import Foundation
import Combine
import CloudKit

extension SQLCipher {
    /// Configures CloudKit sync for this database.
    ///
    /// Call this after initializing the database to set up sync behavior.
    /// Use `.mirrorAll` to automatically sync all user tables, or
    /// `.mirror(tables: [...])` to sync specific tables.
    ///
    /// - Parameter configuration: The sync configuration to apply.
    public func configureSync(_ configuration: SyncConfiguration) {
        self.syncConfiguration = configuration

        Task {
            await SQLCipherCloudKitSyncEngine.shared.configure(db: self)
        }
    }

    /// Adds a table to the sync configuration.
    ///
    /// - Parameters:
    ///   - table: The name of the table to sync.
    ///   - strategy: The sync strategy for this table. Defaults to `.snapshot`.
    public func addSyncedTable(_ table: String, strategy: TableSyncStrategy = .snapshot) {
        if syncConfiguration == nil {
            syncConfiguration = SyncConfiguration()
        }
        syncConfiguration?.tableConfigs[table] = TableSyncConfig(strategy: strategy)

        Task {
            await SQLCipherCloudKitSyncEngine.shared.addTable(db: self, table: table)
        }
    }

    /// Removes a table from the sync configuration.
    ///
    /// - Parameter table: The name of the table to stop syncing.
    public func removeSyncedTable(_ table: String) {
        syncConfiguration?.tableConfigs.removeValue(forKey: table)
    }
}
