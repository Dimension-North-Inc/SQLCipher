//
//  SyncConfiguration.swift
//  SQLCipher
//
//  Created by Kimi on 4/23/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import Foundation

/// Defines the top-level sync behavior for a `SQLCipher` database.
public struct SyncConfiguration: Sendable {
    /// Per-table sync configurations keyed by table name.
    public var tableConfigs: [String: TableSyncConfig]

    /// The default conflict resolution policy.
    public var conflictPolicy: ConflictPolicy

    /// The debounce interval before triggering a sync after local changes.
    public var debounceInterval: Duration

    /// Creates a new sync configuration.
    ///
    /// - Parameters:
    ///   - tableConfigs: Per-table sync configurations.
    ///   - conflictPolicy: How to resolve conflicts between local and remote data.
    ///   - debounceInterval: Time to wait after local changes before syncing.
    public init(
        tableConfigs: [String: TableSyncConfig] = [:],
        conflictPolicy: ConflictPolicy = .lastWriteWins,
        debounceInterval: Duration = .seconds(2)
    ) {
        self.tableConfigs = tableConfigs
        self.conflictPolicy = conflictPolicy
        self.debounceInterval = debounceInterval
    }

    /// Mirrors all user tables (excluding SQLite system tables and sync metadata).
    public static var mirrorAll: SyncConfiguration {
        SyncConfiguration(
            tableConfigs: [:],
            conflictPolicy: .lastWriteWins,
            debounceInterval: .seconds(2)
        )
    }

    /// Mirrors only the specified tables using the default snapshot strategy.
    ///
    /// - Parameter tables: The names of tables to sync.
    /// - Returns: A sync configuration that mirrors the given tables.
    public static func mirror(tables: [String]) -> SyncConfiguration {
        var configs: [String: TableSyncConfig] = [:]
        for table in tables {
            configs[table] = TableSyncConfig(strategy: .snapshot)
        }
        return SyncConfiguration(tableConfigs: configs)
    }
}

/// Per-table sync configuration.
public struct TableSyncConfig: Sendable {
    /// The sync strategy for this table.
    public var strategy: TableSyncStrategy

    /// Creates a per-table sync configuration.
    ///
    /// - Parameter strategy: The sync strategy to use for this table.
    public init(strategy: TableSyncStrategy) {
        self.strategy = strategy
    }
}

/// Defines how a table's data is serialized for CloudKit sync.
public enum TableSyncStrategy: Sendable, Equatable {
    /// Export the entire table contents as a single snapshot.
    case snapshot

    /// Export only rows that changed, keyed by the given primary key column.
    case delta(primaryKey: String)

    /// For `stored_substates`, uses per-substate diffing to avoid syncing unchanged substates.
    case substateAware
}

/// Conflict resolution policy for inbound remote changes.
public enum ConflictPolicy: Sendable {
    /// Remote data always wins over local data.
    case remoteWins

    /// Local data always wins over remote data.
    case localWins

    /// The most recent modification (by timestamp) wins.
    case lastWriteWins
}
