//
//  ChangeTrackerTests.swift
//  SQLCipherTests
//
//  Created by Kimi on 4/23/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import XCTest
@testable import SQLCipher

final class ChangeTrackerTests: XCTestCase {
    func testEmptyFlush() {
        let tracker = ChangeTracker()
        let tables = tracker.flush()
        XCTAssertTrue(tables.isEmpty)
    }

    func testRecordsSingleTable() {
        let tracker = ChangeTracker()
        tracker.record(table: "users")
        let tables = tracker.flush()
        XCTAssertEqual(tables, ["users"])
    }

    func testRecordsMultipleTables() {
        let tracker = ChangeTracker()
        tracker.record(table: "users")
        tracker.record(table: "orders")
        tracker.record(table: "products")
        let tables = tracker.flush()
        XCTAssertEqual(tables, ["orders", "products", "users"])
    }

    func testDeduplicatesTables() {
        let tracker = ChangeTracker()
        tracker.record(table: "users")
        tracker.record(table: "users")
        tracker.record(table: "users")
        let tables = tracker.flush()
        XCTAssertEqual(tables, ["users"])
    }

    func testFlushClearsAccumulator() {
        let tracker = ChangeTracker()
        tracker.record(table: "users")
        _ = tracker.flush()
        let secondFlush = tracker.flush()
        XCTAssertTrue(secondFlush.isEmpty)
    }

    func testRecordsManyTables() {
        let tracker = ChangeTracker()
        let expected = Set((0..<100).map { "table_\($0)" })
        for table in expected {
            tracker.record(table: table)
        }
        let tables = tracker.flush()
        XCTAssertEqual(tables, expected)
    }
}
