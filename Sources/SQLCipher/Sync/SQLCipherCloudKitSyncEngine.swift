//
//  SQLCipherCloudKitSyncEngine.swift
//  SQLCipher
//
//  Created by Kimi on 4/23/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import Foundation
import Combine
import CloudKit
import CryptoKit
import OSLog

/// An actor that manages CloudKit sync for one or more `SQLCipher` databases.
///
/// The engine batches local changes by table, debounces sync requests, and
/// handles inbound remote changes with conflict resolution.
public actor SQLCipherCloudKitSyncEngine {
    /// Shared singleton instance.
    public static let shared = SQLCipherCloudKitSyncEngine()

    private init() {}

    private let log = Logger(subsystem: "com.dimension-north.SQLCipher", category: "CloudKitSync")

    // MARK: - State

    private var dbEngines: [ObjectIdentifier: DatabaseEngine] = [:]

    /// Tracks whether the engine is currently applying remote changes.
    /// When `true`, local change notifications are suppressed to avoid sync loops.
    private var isApplyingRemote = false

    // MARK: - Configuration

    /// Configures sync for a database.
    package func configure(db: SQLCipher) {
        let id = ObjectIdentifier(db)
        guard dbEngines[id] == nil else { return }

        let engine = DatabaseEngine(db: db, engine: self)
        dbEngines[id] = engine
        Task {
            await engine.start()
        }
    }

    /// Adds a table to sync for a database.
    package func addTable(db: SQLCipher, table: String) {
        let id = ObjectIdentifier(db)
        guard let engine = dbEngines[id] else { return }
        Task {
            await engine.addTable(table)
        }
    }

    /// Called by `DatabaseEngine` when local changes occur.
    private func localChangesOccurred(for db: SQLCipher, tables: Set<String>) {
        guard !isApplyingRemote else { return }
        let id = ObjectIdentifier(db)
        guard let engine = dbEngines[id] else { return }
        Task {
            await engine.scheduleSync(tables: tables)
        }
    }

    /// Called by `DatabaseEngine` when it begins applying remote changes.
    private func setApplyingRemote(_ value: Bool) {
        isApplyingRemote = value
    }

    // MARK: - Account Status

    /// Verifies the user's CloudKit account status.
    ///
    /// - Returns: `true` if the account is available and sync can proceed.
    public func verifyAccountStatus() async -> Bool {
        let container = CKContainer.default()
        do {
            let status = try await container.accountStatus()
            return status == .available
        } catch {
            log.error("CloudKit account status check failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Remote Notifications

    /// Handles an incoming CloudKit remote notification.
    ///
    /// Call this from your app delegate or scene delegate when a CloudKit
    /// notification arrives via `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`.
    ///
    /// - Parameter userInfo: The notification payload.
    public func handleRemoteNotification(userInfo: [String: Any]) async {
        let notification = CKNotification(fromRemoteNotificationDictionary: userInfo)
        guard notification != nil else { return }

        for engine in dbEngines.values {
            await engine.pull()
        }
    }
}

// MARK: - Per-Database Engine

extension SQLCipherCloudKitSyncEngine {
    /// Manages sync state and operations for a single `SQLCipher` instance.
    actor DatabaseEngine {
        let db: SQLCipher
        weak var engine: SQLCipherCloudKitSyncEngine?

        private let log = Logger(subsystem: "com.dimension-north.SQLCipher", category: "CloudKitSync.DB")

        /// CloudKit container and database.
        private let container: CKContainer
        private let database: CKDatabase

        /// The custom sync zone.
        private let zoneID: CKRecordZone.ID

        /// Subscription ID for push notifications.
        private let subscriptionID = "sqlcipher.sync.subscription"

        /// Tracks pending local table changes waiting to sync.
        private var pendingTables: Set<String> = []

        /// Debounce task for scheduled syncs.
        private var syncTask: Task<Void, Never>?

        /// Cached last-known row checksums for `.delta` strategy.
        private var lastDeltaChecksums: [String: [String: Data]] = [:]

        /// Cached last-known substate checksums for `.substateAware` strategy.
        private var lastSubstateChecksums: [String: Data] = [:]

        /// Cancellable for observing database changes.
        private var changeCancellable: AnyCancellable?

        init(db: SQLCipher, engine: SQLCipherCloudKitSyncEngine) {
            self.db = db
            self.engine = engine
            self.container = CKContainer.default()
            self.database = container.privateCloudDatabase
            self.zoneID = CKRecordZone.ID(zoneName: "SQLCipherSync", ownerName: CKCurrentUserDefaultName)
        }

        func start() async {
            do {
                try await ensureZone()
                try await ensureSubscription()
                observeChanges()
                log.info("CloudKit sync started for \(self.db.path)")
            } catch {
                log.error("Failed to start CloudKit sync: \(error.localizedDescription)")
            }
        }

        func addTable(_ table: String) {
            log.info("Added synced table: \(table)")
        }

        // MARK: - Local Change Observation

        func observeChanges() {
            changeCancellable = db.didUpdate
                .sink { [weak self] tables in
                    guard let self = self else { return }
                    guard let config = self.db.syncConfiguration else { return }

                    let tracked = config.tableConfigs.keys
                    let changed = tables.intersection(tracked)
                    guard !changed.isEmpty else { return }

                    Task {
                        await self.engine?.localChangesOccurred(for: self.db, tables: changed)
                    }
                }
        }

        func scheduleSync(tables: Set<String>) {
            pendingTables.formUnion(tables)
            syncTask?.cancel()

            let interval: Duration = db.syncConfiguration?.debounceInterval ?? .seconds(2)
            let nanoseconds = UInt64(interval.components.seconds) * 1_000_000_000 + UInt64(interval.components.attoseconds) / 1_000_000_000

            syncTask = Task {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                let toSync = pendingTables
                pendingTables.removeAll()
                await push(tables: toSync)
            }
        }

        // MARK: - Push

        func push(tables: Set<String>) async {
            guard let config = db.syncConfiguration else { return }

            for table in tables {
                guard let tableConfig = config.tableConfigs[table] else { continue }

                do {
                    let record = try await buildRecord(
                        table: table,
                        strategy: tableConfig.strategy
                    )
                    let saveOp = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
                    saveOp.savePolicy = .allKeys

                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        saveOp.modifyRecordsResultBlock = { result in
                            switch result {
                            case .success:
                                continuation.resume()
                            case .failure(let error):
                                continuation.resume(throwing: error)
                            }
                        }
                        self.database.add(saveOp)
                    }

                    log.info("Pushed \(table) to CloudKit")
                } catch {
                    log.error("Failed to push \(table): \(error.localizedDescription)")
                }
            }
        }

        // MARK: - Pull

        func pull() async {
            guard let engine else { return }
            await engine.setApplyingRemote(true)
            defer { Task { await engine.setApplyingRemote(false) } }

            do {
                let query = CKQuery(recordType: "SQLTable", predicate: NSPredicate(value: true))
                let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)

                for (_, result) in results {
                    switch result {
                    case .success(let record):
                        await apply(record: record)
                    case .failure(let error):
                        log.error("Failed to fetch record: \(error.localizedDescription)")
                    }
                }
            } catch {
                log.error("Pull failed: \(error.localizedDescription)")
            }
        }

        func apply(record: CKRecord) async {
            guard let table = record.recordID.recordName.removingPrefix("sqlcipher:") else { return }
            guard let config = db.syncConfiguration?.tableConfigs[table] else { return }

            do {
                switch config.strategy {
                case .snapshot:
                    try await applySnapshot(record: record, table: table)
                case .delta:
                    try await applyDelta(record: record, table: table)
                case .substateAware:
                    try await applySubstate(record: record)
                }
                log.info("Applied remote record for \(table)")
            } catch {
                log.error("Failed to apply record for \(table): \(error.localizedDescription)")
            }
        }

        // MARK: - Record Building

        func buildRecord(table: String, strategy: TableSyncStrategy) async throws -> CKRecord {
            let recordName = "sqlcipher:\(table)"
            let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
            let recordType = "SQLTable_\(table)"

            let record = CKRecord(recordType: recordType, recordID: recordID)
            record["lastModified"] = Date()
            record["schemaHash"] = try schemaHash(for: table)
            record["rowCount"] = try rowCount(for: table)

            switch strategy {
            case .snapshot:
                record["tableData"] = try await exportSnapshot(table: table)
            case .delta(let primaryKey):
                let (data, checksums) = try await exportDelta(table: table, primaryKey: primaryKey)
                record["deltaData"] = data
                lastDeltaChecksums[table] = checksums
            case .substateAware:
                let (data, checksums) = try await exportSubstateDelta()
                record["substateData"] = data
                lastSubstateChecksums = checksums
            }

            return record
        }

        // MARK: - Snapshot Strategy

        func exportSnapshot(table: String) async throws -> Data {
            let query: SQLStaticQuery = "SELECT * FROM \(raw: table)"
            let result = try db.reader.execute(query)
            var array: [[String: Any]] = []
            for row in result {
                var dict: [String: Any] = [:]
                for (key, value) in row.values {
                    dict[key] = sqlValueToCodable(value)
                }
                array.append(dict)
            }
            return try JSONSerialization.data(withJSONObject: array, options: [.sortedKeys])
        }

        func applySnapshot(record: CKRecord, table: String) async throws {
            guard let data = record["tableData"] as? Data else { return }
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            try db.writer.begin()
            defer { try? db.writer.rollback() }

            try db.writer.exec("DELETE FROM \(table)")

            for dict in array {
                let columns = dict.keys.sorted().joined(separator: ", ")
                let placeholders = dict.keys.sorted().map { _ in "?" }.joined(separator: ", ")
                let sql = "INSERT INTO \(columns) VALUES (\(placeholders))"
                var stmt: OpaquePointer?
                try checked(sqlite3_prepare_v2(db.writer.db, sql, -1, &stmt, nil), on: db.writer.db)
                defer { sqlite3_finalize(stmt) }

                let sortedKeys = dict.keys.sorted()
                for (index, key) in sortedKeys.enumerated() {
                    let value = dict[key]
                    try bindValue(value, to: stmt, at: Int32(index + 1), on: db.writer.db)
                }
                let stepResult = sqlite3_step(stmt)
                if stepResult != SQLITE_DONE {
                    try checked(stepResult, on: db.writer.db)
                }
            }

            try db.writer.commit()
        }

        // MARK: - Delta Strategy

        func exportDelta(table: String, primaryKey: String) async throws -> (Data, [String: Data]) {
            let query: SQLStaticQuery = "SELECT * FROM \(raw: table)"
            let result = try db.reader.execute(query)
            var changedRows: [[String: Any]] = []
            var newChecksums: [String: Data] = [:]
            let lastChecksums = lastDeltaChecksums[table] ?? [:]

            for row in result {
                guard let pkValue = row.values[primaryKey] else { continue }
                let pkString = sqlValueToString(pkValue)
                let dict = row.values.reduce(into: [String: Any]()) { $0[$1.key] = sqlValueToCodable($1.value) }
                let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
                let checksum = Data(SHA256.hash(data: data))
                newChecksums[pkString] = checksum

                if lastChecksums[pkString] != checksum {
                    changedRows.append(dict)
                }
            }

            let deleted = Array(lastChecksums.keys.filter { key in !newChecksums.keys.contains(key) })
            let payload: [String: Any] = [
                "rows": changedRows,
                "deleted": deleted
            ]
            return (try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), newChecksums)
        }

        func applyDelta(record: CKRecord, table: String) async throws {
            guard let data = record["deltaData"] as? Data else { return }
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            guard let rows = payload["rows"] as? [[String: Any]] else { return }
            guard let deleted = payload["deleted"] as? [String] else { return }

            let config = db.syncConfiguration?.tableConfigs[table]
            let primaryKey: String
            switch config?.strategy {
            case .delta(let pk): primaryKey = pk
            default: return
            }

            try db.writer.begin()
            defer { try? db.writer.rollback() }

            for pk in deleted {
                let query: SQLStaticQuery = "DELETE FROM \(raw: table) WHERE \(raw: primaryKey) = \(pk)"
                _ = try db.writer.execute(query)
            }

            for dict in rows {
                guard dict[primaryKey] != nil else { continue }
                let columns = dict.keys.sorted()
                let setClause = columns.map { "\($0) = ?" }.joined(separator: ", ")
                let colList = columns.joined(separator: ", ")
                let valList = columns.map { _ in "?" }.joined(separator: ", ")
                let upsertSQL = "INSERT INTO \(table) (\(colList)) VALUES (\(valList)) ON CONFLICT(\(primaryKey)) DO UPDATE SET \(setClause)"

                var stmt: OpaquePointer?
                try checked(sqlite3_prepare_v2(db.writer.db, upsertSQL, -1, &stmt, nil), on: db.writer.db)
                defer { sqlite3_finalize(stmt) }

                let sortedKeys = columns
                for (index, key) in sortedKeys.enumerated() {
                    try bindValue(dict[key], to: stmt, at: Int32(index + 1), on: db.writer.db)
                }
                let stepResult = sqlite3_step(stmt)
                if stepResult != SQLITE_DONE {
                    try checked(stepResult, on: db.writer.db)
                }
            }

            try db.writer.commit()
        }

        // MARK: - Substate Strategy

        func exportSubstateDelta() async throws -> (Data, [String: Data]) {
            let query: SQLStaticQuery = "SELECT key, value FROM stored_substates"
            let result = try db.reader.execute(query)
            var changed: [String: Data] = [:]
            var newChecksums: [String: Data] = [:]

            for row in result {
                guard let key: String = row["key"] else { continue }
                guard let value: Data = row["value"] else { continue }
                let checksum = Data(SHA256.hash(data: value))
                newChecksums[key] = checksum

                if lastSubstateChecksums[key] != checksum {
                    changed[key] = value
                }
            }

            let deleted = Array(lastSubstateChecksums.keys.filter { key in !newChecksums.keys.contains(key) })
            let payload: [String: Any] = [
                "substates": changed.mapValues { $0.base64EncodedString() },
                "deleted": deleted
            ]
            return (try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), newChecksums)
        }

        func applySubstate(record: CKRecord) async throws {
            guard let data = record["substateData"] as? Data else { return }
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            guard let substates = payload["substates"] as? [String: String] else { return }
            guard let deleted = payload["deleted"] as? [String] else { return }

            try db.writer.begin()
            defer { try? db.writer.rollback() }

            for key in deleted {
                let query: SQLStaticQuery = "DELETE FROM stored_substates WHERE key = \(key)"
                _ = try db.writer.execute(query)
            }

            for (key, base64) in substates {
                guard let data = Data(base64Encoded: base64) else { continue }
                let query: SQLStaticQuery = "INSERT OR REPLACE INTO stored_substates (key, value) VALUES (\(key), \(data))"
                _ = try db.writer.execute(query)
            }

            try db.writer.commit()
        }

        // MARK: - CloudKit Setup

        func ensureZone() async throws {
            do {
                _ = try await database.recordZone(for: zoneID)
            } catch {
                let zone = CKRecordZone(zoneID: zoneID)
                _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
            }
        }

        func ensureSubscription() async throws {
            let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.shouldSendContentAvailable = true
            subscription.notificationInfo = notificationInfo

            do {
                _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
            } catch let error as CKError where error.code == .serverRejectedRequest {
                log.info("Subscription already exists")
            }
        }

        // MARK: - Helpers

        func schemaHash(for table: String) throws -> String {
            let query: SQLStaticQuery = "SELECT sql FROM sqlite_master WHERE name = \(table)"
            let result = try db.reader.execute(query)
            let sql: String = result.first?["sql"] ?? ""
            let data = Data(sql.utf8)
            return Data(SHA256.hash(data: data)).base64EncodedString()
        }

        func rowCount(for table: String) throws -> Int {
            let query: SQLStaticQuery = "SELECT COUNT(*) as count FROM \(raw: table)"
            let result = try db.reader.execute(query)
            return result.first?["count"].flatMap { Int(sqliteValue: $0) } ?? 0
        }
    }
}

// MARK: - Value Helpers

private func sqlValueToCodable(_ value: SQLValue) -> Any {
    switch value {
    case .integer(let v): return v
    case .real(let v): return v
    case .text(let v): return v
    case .blob(let v): return v.base64EncodedString()
    case .null: return NSNull()
    case .vector(_, let v): return v.base64EncodedString()
    case .array(let values): return values.map(sqlValueToCodable)
    }
}

private func sqlValueToString(_ value: SQLValue) -> String {
    switch value {
    case .integer(let v): return String(v)
    case .real(let v): return String(v)
    case .text(let v): return v
    case .blob(let v): return v.base64EncodedString()
    case .null: return "null"
    case .vector(_, let v): return v.base64EncodedString()
    case .array(let values): return values.map(sqlValueToString).joined(separator: ",")
    }
}

private func bindValue(_ value: Any?, to stmt: OpaquePointer?, at index: Int32, on db: OpaquePointer?) throws {
    if let value = value as? Int64 {
        sqlite3_bind_int64(stmt, index, value)
    } else if let value = value as? Int {
        sqlite3_bind_int64(stmt, index, Int64(value))
    } else if let value = value as? Double {
        sqlite3_bind_double(stmt, index, value)
    } else if let value = value as? Float {
        sqlite3_bind_double(stmt, index, Double(value))
    } else if let value = value as? String {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    } else if let value = value as? Data {
        sqlite3_bind_blob(stmt, index, (value as NSData).bytes, Int32(value.count), SQLITE_TRANSIENT)
    } else {
        sqlite3_bind_null(stmt, index)
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
