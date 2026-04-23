//
//  SQLCipherSyncTests.swift
//  SQLCipherTests
//
//  Created by Kimi on 4/23/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import XCTest
import Combine
@testable import SQLCipher

final class SQLCipherSyncTests: XCTestCase {
    var db: SQLCipher!
    var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        cancellables = []
    }

    override func tearDown() {
        cancellables = nil
        db = nil
        super.tearDown()
    }

    func testDidUpdatePublishesChangedTables() throws {
        db = try SQLCipher(path: ":memory:")

        let expectation = self.expectation(description: "didUpdate publishes tables")
        expectation.assertForOverFulfill = false
        var receivedTables: Set<String> = []

        db.didUpdate
            .dropFirst() // Skip initial empty value
            .sink { tables in
                receivedTables = tables
                expectation.fulfill()
            }
            .store(in: &cancellables)

        try db.writer.exec("CREATE TABLE publisher_test (id INTEGER PRIMARY KEY)")
        try db.writer.exec("INSERT INTO publisher_test (id) VALUES (1)")

        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(receivedTables.contains("publisher_test"))
    }

    func testDidUpdatePublishesMultipleTables() throws {
        db = try SQLCipher(path: ":memory:")

        let expectation = self.expectation(description: "didUpdate publishes multiple tables")
        expectation.expectedFulfillmentCount = 2
        expectation.assertForOverFulfill = false
        var allTables: [Set<String>] = []

        db.didUpdate
            .dropFirst()
            .sink { tables in
                allTables.append(tables)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        try db.writer.exec("CREATE TABLE multi_a (id INTEGER PRIMARY KEY)")
        try db.writer.exec("CREATE TABLE multi_b (id INTEGER PRIMARY KEY)")
        try db.writer.exec("INSERT INTO multi_a (id) VALUES (1)")
        try db.writer.exec("INSERT INTO multi_b (id) VALUES (2)")

        wait(for: [expectation], timeout: 1.0)
        XCTAssertGreaterThanOrEqual(allTables.count, 2)
        XCTAssertTrue(allTables.contains(where: { $0.contains("multi_a") }))
        XCTAssertTrue(allTables.contains(where: { $0.contains("multi_b") }))
    }

    func testConfigureSyncStoresConfiguration() throws {
        db = try SQLCipher(path: ":memory:")

        let config = SyncConfiguration(
            tableConfigs: ["users": TableSyncConfig(strategy: .snapshot)],
            conflictPolicy: .remoteWins,
            debounceInterval: .seconds(5)
        )

        // Set configuration directly to avoid CloudKit engine initialization in tests
        db.syncConfiguration = config

        XCTAssertNotNil(db.syncConfiguration)
        XCTAssertEqual(db.syncConfiguration?.conflictPolicy, .remoteWins)
        XCTAssertEqual(db.syncConfiguration?.debounceInterval, .seconds(5))
        XCTAssertEqual(db.syncConfiguration?.tableConfigs["users"]?.strategy, .snapshot)
    }

    func testAddSyncedTableUpdatesConfiguration() throws {
        db = try SQLCipher(path: ":memory:")

        // Set configuration directly to avoid CloudKit engine initialization in tests
        db.syncConfiguration = SyncConfiguration()
        db.syncConfiguration?.tableConfigs["products"] = TableSyncConfig(strategy: .snapshot)
        db.syncConfiguration?.tableConfigs["events"] = TableSyncConfig(strategy: .delta(primaryKey: "event_id"))

        XCTAssertNotNil(db.syncConfiguration)
        XCTAssertEqual(db.syncConfiguration?.tableConfigs["products"]?.strategy, .snapshot)
        XCTAssertEqual(db.syncConfiguration?.tableConfigs["events"]?.strategy, .delta(primaryKey: "event_id"))
    }

    func testMirrorAllConfiguration() {
        let config = SyncConfiguration.mirrorAll
        XCTAssertTrue(config.tableConfigs.isEmpty)
        XCTAssertEqual(config.conflictPolicy, .lastWriteWins)
        XCTAssertEqual(config.debounceInterval, .seconds(2))
    }

    func testMirrorTablesConfiguration() {
        let config = SyncConfiguration.mirror(tables: ["users", "orders"])
        XCTAssertEqual(config.tableConfigs["users"]?.strategy, .snapshot)
        XCTAssertEqual(config.tableConfigs["orders"]?.strategy, .snapshot)
    }

    func testRemoveSyncedTable() throws {
        db = try SQLCipher(path: ":memory:")
        db.syncConfiguration = .mirror(tables: ["users", "orders"])
        db.removeSyncedTable("users")

        XCTAssertNil(db.syncConfiguration?.tableConfigs["users"])
        XCTAssertNotNil(db.syncConfiguration?.tableConfigs["orders"])
    }
}
