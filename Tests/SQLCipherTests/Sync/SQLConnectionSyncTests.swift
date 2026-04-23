//
//  SQLConnectionSyncTests.swift
//  SQLCipherTests
//
//  Created by Kimi on 4/23/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import XCTest
@testable import SQLCipher

final class SQLConnectionSyncTests: XCTestCase {
    var dbPath: String!

    override func setUp() {
        super.setUp()
        let tempDir = FileManager.default.temporaryDirectory
        dbPath = tempDir.appendingPathComponent(UUID().uuidString + ".db").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    func testUpdateHookAccumulatesTableNames() throws {
        let writer = try SQLConnection(path: dbPath, role: .writer)

        try writer.exec("CREATE TABLE test_table (id INTEGER PRIMARY KEY, name TEXT)")

        // Begin a transaction so the commit hook doesn't flush early
        try writer.begin()
        try writer.exec("INSERT INTO test_table (name) VALUES ('alice')")

        // The tracker should have accumulated the table name before commit
        let tables = writer.changeTracker.flush()
        XCTAssertTrue(tables.contains("test_table"), "Should track test_table")

        try writer.rollback()
    }

    func testCommitHookFlushesTrackedTables() throws {
        let writer = try SQLConnection(path: dbPath, role: .writer)
        var committedTables: Set<String> = []

        writer.onCommitted = { tables in
            committedTables = tables
            return SQLITE_OK
        }

        try writer.exec("CREATE TABLE commit_test (id INTEGER PRIMARY KEY)")
        try writer.begin()
        try writer.exec("INSERT INTO commit_test (id) VALUES (1)")
        try writer.commit()

        XCTAssertTrue(committedTables.contains("commit_test"), "onCommitted should receive commit_test")
        XCTAssertTrue(writer.changeTracker.flush().isEmpty, "changeTracker should be empty after commit")
    }

    func testRollbackHookClearsTrackedTables() throws {
        let writer = try SQLConnection(path: dbPath, role: .writer)
        var committedTables: Set<String> = []

        writer.onCommitted = { tables in
            committedTables = tables
            return SQLITE_OK
        }

        try writer.exec("CREATE TABLE rollback_test (id INTEGER PRIMARY KEY)")
        try writer.begin()
        try writer.exec("INSERT INTO rollback_test (id) VALUES (1)")
        try writer.rollback()

        XCTAssertTrue(committedTables.isEmpty, "onCommitted should not be called for rollback")
        XCTAssertTrue(writer.changeTracker.flush().isEmpty, "changeTracker should be empty after rollback")
    }

    func testMultipleTablesInSingleTransaction() throws {
        let writer = try SQLConnection(path: dbPath, role: .writer)
        var committedTables: Set<String> = []

        writer.onCommitted = { tables in
            committedTables = tables
            return SQLITE_OK
        }

        try writer.exec("CREATE TABLE table_a (id INTEGER PRIMARY KEY)")
        try writer.exec("CREATE TABLE table_b (id INTEGER PRIMARY KEY)")
        try writer.begin()
        try writer.exec("INSERT INTO table_a (id) VALUES (1)")
        try writer.exec("INSERT INTO table_b (id) VALUES (2)")
        try writer.commit()

        XCTAssertEqual(committedTables.sorted(), ["table_a", "table_b"])
    }

    func testAutocommitTracksTables() throws {
        let writer = try SQLConnection(path: dbPath, role: .writer)
        var committedTables: Set<String> = []

        writer.onCommitted = { tables in
            committedTables = tables
            return SQLITE_OK
        }

        try writer.exec("CREATE TABLE auto_test (id INTEGER PRIMARY KEY)")

        // Without explicit transaction, each DML statement is its own transaction
        committedTables.removeAll()
        try writer.exec("INSERT INTO auto_test (id) VALUES (1)")
        XCTAssertTrue(committedTables.contains("auto_test"), "Insert should trigger onCommitted")

        committedTables.removeAll()
        try writer.exec("INSERT INTO auto_test (id) VALUES (2)")
        XCTAssertTrue(committedTables.contains("auto_test"), "Second insert should trigger onCommitted")
    }

    func testOnUpdateFallbackWhenOnCommittedIsNil() throws {
        let writer = try SQLConnection(path: dbPath, role: .writer)
        var updateCalled = false

        writer.onCommitted = nil
        writer.onUpdate = { _ in
            updateCalled = true
            return SQLITE_OK
        }

        try writer.exec("CREATE TABLE fallback_test (id INTEGER PRIMARY KEY)")
        try writer.exec("INSERT INTO fallback_test (id) VALUES (1)")
        XCTAssertTrue(updateCalled, "onUpdate should be called when onCommitted is nil")
    }
}
