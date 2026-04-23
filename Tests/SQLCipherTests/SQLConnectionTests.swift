//
//  SQLConnectionTests.swift
//  SQLCipherTests
//
//  Created by Kimi on 4/23/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import Testing
import Foundation
@testable import SQLCipher

@Suite struct SQLConnectionTests {
    func tempDBPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("db")
            .path
    }

    @Test func testReaderCannotWrite() throws {
        let path = tempDBPath()
        // Create the DB with a writer first
        let writer = try SQLConnection(path: path, role: .writer)
        try writer.exec("CREATE TABLE test (id INTEGER PRIMARY KEY)")

        let reader = try SQLConnection(path: path, role: .reader)
        #expect(throws: SQLiteError.self) {
            try reader.exec("INSERT INTO test (id) VALUES (1)")
        }
    }

    @Test func testSavepointCommit() throws {
        let writer = try SQLConnection(path: tempDBPath(), role: .writer)
        try writer.exec("CREATE TABLE sp_test (id INTEGER PRIMARY KEY)")

        try writer.begin(savepoint: "sp1")
        try writer.exec("INSERT INTO sp_test (id) VALUES (1)")
        try writer.commit(savepoint: "sp1")

        let result = try writer.execute("SELECT COUNT(*) as cnt FROM sp_test")
        #expect(result.first?["cnt"].flatMap { Int(sqliteValue: $0) } == 1)
    }

    @Test func testSavepointRollback() throws {
        let writer = try SQLConnection(path: tempDBPath(), role: .writer)
        try writer.exec("CREATE TABLE sp_test (id INTEGER PRIMARY KEY)")
        try writer.exec("INSERT INTO sp_test (id) VALUES (1)")

        try writer.begin(savepoint: "sp1")
        try writer.exec("INSERT INTO sp_test (id) VALUES (2)")
        try writer.rollback(savepoint: "sp1")

        let result = try writer.execute("SELECT COUNT(*) as cnt FROM sp_test")
        #expect(result.first?["cnt"].flatMap { Int(sqliteValue: $0) } == 1)
    }

    @Test func testNestedSavepoints() throws {
        let writer = try SQLConnection(path: tempDBPath(), role: .writer)
        try writer.exec("CREATE TABLE nested_test (id INTEGER PRIMARY KEY)")

        try writer.begin()
        try writer.exec("INSERT INTO nested_test (id) VALUES (1)")

        try writer.begin(savepoint: "inner")
        try writer.exec("INSERT INTO nested_test (id) VALUES (2)")
        try writer.rollback(savepoint: "inner")

        try writer.commit()

        let result = try writer.execute("SELECT COUNT(*) as cnt FROM nested_test")
        #expect(result.first?["cnt"].flatMap { Int(sqliteValue: $0) } == 1)
    }

    @Test func testInvalidSQLThrows() throws {
        let writer = try SQLConnection(path: tempDBPath(), role: .writer)
        #expect(throws: SQLiteError.self) {
            try writer.exec("THIS IS NOT SQL")
        }
    }

    @Test func testPreparedQueryReuse() throws {
        let writer = try SQLConnection(path: tempDBPath(), role: .writer)
        try writer.exec("CREATE TABLE reuse_test (id INTEGER PRIMARY KEY, name TEXT)")

        struct Params {
            var id: Int
            var name: String
        }
        let query: SQLQuery<Params> = "INSERT INTO reuse_test (id, name) VALUES (\(\.id), \(\.name))"
        let prepared = try writer.prepare(query)

        try prepared.execute(Params(id: 1, name: "Alice"))
        try prepared.execute(Params(id: 2, name: "Bob"))
        try prepared.execute(Params(id: 3, name: "Charlie"))

        let result = try writer.execute("SELECT COUNT(*) as cnt FROM reuse_test")
        #expect(result.first?["cnt"].flatMap { Int(sqliteValue: $0) } == 3)
    }

    @Test func testResetKey() throws {
        let path = tempDBPath()
        // Create an initially encrypted database
        var db = try SQLConnection(path: path, key: "original-secret", role: .writer)
        try db.exec("CREATE TABLE key_test (id INTEGER PRIMARY KEY)")
        try db.exec("INSERT INTO key_test (id) VALUES (1)")

        // Rekey to a new password
        try db.resetKey("new-secret")
        #expect(db.isEncrypted == true)

        // Re-open with new key should work
        db = try SQLConnection(path: path, key: "new-secret", role: .writer)
        let result = try db.execute("SELECT COUNT(*) as cnt FROM key_test")
        #expect(result.first?["cnt"].flatMap { Int(sqliteValue: $0) } == 1)

        // Old key should fail
        #expect(throws: SQLiteError.self) {
            let _ = try SQLConnection(path: path, key: "original-secret", role: .writer)
        }
    }

    @Test func testConcurrentReaders() throws {
        let path = tempDBPath()
        let writer = try SQLConnection(path: path, role: .writer)
        try writer.exec("CREATE TABLE concurrent (id INTEGER PRIMARY KEY, value TEXT)")
        for i in 0..<100 {
            try writer.exec("INSERT INTO concurrent (id, value) VALUES (\(i), 'item\(i)')")
        }

        let reader1 = try SQLConnection(path: path, role: .reader)
        let reader2 = try SQLConnection(path: path, role: .reader)

        let group = DispatchGroup()
        var count1 = 0
        var count2 = 0

        group.enter()
        DispatchQueue.global().async {
            do {
                let result = try reader1.execute("SELECT COUNT(*) as cnt FROM concurrent")
                count1 = result.first?["cnt"].flatMap { Int(sqliteValue: $0) } ?? -1
            } catch {
                count1 = -2
            }
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            do {
                let result = try reader2.execute("SELECT COUNT(*) as cnt FROM concurrent")
                count2 = result.first?["cnt"].flatMap { Int(sqliteValue: $0) } ?? -1
            } catch {
                count2 = -2
            }
            group.leave()
        }

        group.wait()

        #expect(count1 == 100)
        #expect(count2 == 100)
    }
}
