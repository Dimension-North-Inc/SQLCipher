//
//  SyncConfigurationTests.swift
//  SQLCipherTests
//
//  Created by Kimi on 4/23/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import XCTest
@testable import SQLCipher

final class SyncConfigurationTests: XCTestCase {
    func testSyncConfigurationDefaults() {
        let config = SyncConfiguration()
        XCTAssertTrue(config.tableConfigs.isEmpty)
        XCTAssertEqual(config.conflictPolicy, .lastWriteWins)
        XCTAssertEqual(config.debounceInterval, .seconds(2))
    }

    func testSyncConfigurationCustomValues() {
        let config = SyncConfiguration(
            tableConfigs: ["test": TableSyncConfig(strategy: .snapshot)],
            conflictPolicy: .remoteWins,
            debounceInterval: .milliseconds(500)
        )
        XCTAssertEqual(config.tableConfigs.count, 1)
        XCTAssertEqual(config.conflictPolicy, .remoteWins)
        XCTAssertEqual(config.debounceInterval, .milliseconds(500))
    }

    func testTableSyncConfigSnapshot() {
        let config = TableSyncConfig(strategy: .snapshot)
        if case .snapshot = config.strategy {
            // pass
        } else {
            XCTFail("Expected snapshot strategy")
        }
    }

    func testTableSyncConfigDelta() {
        let config = TableSyncConfig(strategy: .delta(primaryKey: "id"))
        if case .delta(let pk) = config.strategy {
            XCTAssertEqual(pk, "id")
        } else {
            XCTFail("Expected delta strategy")
        }
    }

    func testTableSyncConfigSubstateAware() {
        let config = TableSyncConfig(strategy: .substateAware)
        if case .substateAware = config.strategy {
            // pass
        } else {
            XCTFail("Expected substateAware strategy")
        }
    }

    func testConflictPolicyCases() {
        let policies: [ConflictPolicy] = [.remoteWins, .localWins, .lastWriteWins]
        XCTAssertEqual(policies.count, 3)
    }

    func testSyncConfigurationSendable() {
        // Compile-time check: SyncConfiguration should be Sendable
        let config = SyncConfiguration()
        Task {
            let _: SyncConfiguration = config
        }
    }

    func testTableSyncStrategySendable() {
        // Compile-time check: strategies should be Sendable
        let strategies: [TableSyncStrategy] = [.snapshot, .delta(primaryKey: "id"), .substateAware]
        Task {
            let _: [TableSyncStrategy] = strategies
        }
    }
}
