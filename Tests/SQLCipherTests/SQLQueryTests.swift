//
//  SQLQueryTests.swift
//  SQLCipherTests
//
//  Created by Kimi on 4/23/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import Testing
import Foundation
@testable import SQLCipher

@Suite struct SQLQueryTests {
    func tempDBPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("db")
            .path
    }

    @Test func testInClauseRewriting() {
        struct SearchParams {
            var ids: [Int]
        }
        let query: SQLQuery<SearchParams> = "SELECT * FROM users WHERE id IN (\(\.ids))"
        #expect(query.sql.contains("SELECT value FROM json_each"))
    }

    @Test func testInClauseExecution() throws {
        let db = try SQLCipher(path: tempDBPath())
        try db.writer.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        try db.writer.exec("INSERT INTO users (id, name) VALUES (1, 'Alice')")
        try db.writer.exec("INSERT INTO users (id, name) VALUES (2, 'Bob')")
        try db.writer.exec("INSERT INTO users (id, name) VALUES (3, 'Charlie')")
        try db.writer.exec("INSERT INTO users (id, name) VALUES (4, 'Diana')")

        struct SearchParams {
            var ids: [Int]
        }
        let query: SQLQuery<SearchParams> = "SELECT name FROM users WHERE id IN (\(\.ids)) ORDER BY id"
        let result = try db.reader.execute(query, SearchParams(ids: [1, 3]))

        #expect(result.count == 2)
        #expect(result[0].name == "Alice")
        #expect(result[1].name == "Charlie")
    }

    @Test func testNullParameterBinding() throws {
        let db = try SQLCipher(path: tempDBPath())
        try db.writer.exec("CREATE TABLE nullable (id INTEGER PRIMARY KEY, value TEXT)")

        struct Params {
            var value: String?
        }
        let query: SQLQuery<Params> = "INSERT INTO nullable (id, value) VALUES (1, \(\.value))"
        try db.writer.execute(query, Params(value: nil))

        let result = try db.reader.execute("SELECT value FROM nullable WHERE id = 1")
        #expect(result.count == 1)
        #expect(result[0]["value"] == .null)
    }

    @Test func testEmptyResultSet() throws {
        let db = try SQLCipher(path: tempDBPath())
        try db.writer.exec("CREATE TABLE empty_test (id INTEGER PRIMARY KEY)")

        let result = try db.reader.execute("SELECT * FROM empty_test")
        #expect(result.count == 0)
        #expect(result.rows.isEmpty)
        #expect(result.affectedRows == 0)
    }

    @Test func testAffectedRowsAndLastInsertID() throws {
        let db = try SQLCipher(path: tempDBPath())
        try db.writer.exec("CREATE TABLE affected_test (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")

        let result1 = try db.writer.execute("INSERT INTO affected_test (name) VALUES ('Alice')")
        #expect(result1.affectedRows == 1)
        #expect(result1.lastInsertedRowID == 1)

        let result2 = try db.writer.execute("INSERT INTO affected_test (name) VALUES ('Bob')")
        #expect(result2.affectedRows == 1)
        #expect(result2.lastInsertedRowID == 2)

        let result3 = try db.writer.execute("UPDATE affected_test SET name = 'Updated' WHERE id = 1")
        #expect(result3.affectedRows == 1)

        let result4 = try db.writer.execute("DELETE FROM affected_test WHERE id = 1")
        #expect(result4.affectedRows == 1)
    }

    @Test func testDynamicMemberLookup() throws {
        let db = try SQLCipher(path: tempDBPath())
        try db.writer.exec("CREATE TABLE dynamic_test (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
        try db.writer.exec("INSERT INTO dynamic_test (id, name, age) VALUES (1, 'Alice', 30)")

        let result = try db.reader.execute("SELECT * FROM dynamic_test WHERE id = 1")
        #expect(result.count == 1)

        let name: String? = result[0].name
        let age: Int? = result[0].age
        #expect(name == "Alice")
        #expect(age == 30)
    }

    @Test func testTypeCoercionFailure() throws {
        let db = try SQLCipher(path: tempDBPath())
        try db.writer.exec("CREATE TABLE coerce_test (id INTEGER PRIMARY KEY, name TEXT)")
        try db.writer.exec("INSERT INTO coerce_test (id, name) VALUES (1, 'Alice')")

        let result = try db.reader.execute("SELECT name FROM coerce_test WHERE id = 1")
        #expect(result.count == 1)

        // name is text, so extracting as Int should fail gracefully
        let asInt: Int? = result[0]["name"]
        #expect(asInt == nil)
    }

    @Test func testDateRoundTrip() throws {
        let db = try SQLCipher(path: tempDBPath())
        try db.writer.exec("CREATE TABLE date_test (id INTEGER PRIMARY KEY, created_at TEXT)")

        let now = Date()
        struct Params {
            var created: Date
        }
        let query: SQLQuery<Params> = "INSERT INTO date_test (id, created_at) VALUES (1, \(\.created))"
        try db.writer.execute(query, Params(created: now))

        let result = try db.reader.execute("SELECT created_at FROM date_test WHERE id = 1")
        let recovered: Date? = result[0]["created_at"]
        #expect(recovered != nil)
    }

    @Test func testUUIDRoundTrip() throws {
        let db = try SQLCipher(path: tempDBPath())
        try db.writer.exec("CREATE TABLE uuid_test (id INTEGER PRIMARY KEY, uid TEXT)")

        let uuid = UUID()
        struct Params {
            var uid: UUID
        }
        let query: SQLQuery<Params> = "INSERT INTO uuid_test (id, uid) VALUES (1, \(\.uid))"
        try db.writer.execute(query, Params(uid: uuid))

        let result = try db.reader.execute("SELECT uid FROM uuid_test WHERE id = 1")
        let recovered: UUID? = result[0]["uid"]
        #expect(recovered == uuid)
    }
}
