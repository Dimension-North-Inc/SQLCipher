//
//  SQLCipherEncryptionTests.swift
//  SQLCipherTests
//
//  Created by Kimi on 4/23/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import Testing
import Foundation
@testable import SQLCipher

@Suite struct SQLCipherEncryptionTests {
    func tempDBPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("db")
            .path
    }

    @Test func testCreateEncryptedDatabase() throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path, key: "secret")
        #expect(db.isEncrypted == true)

        try db.writer.exec("CREATE TABLE test (id INTEGER PRIMARY KEY)")
        try db.writer.exec("INSERT INTO test (id) VALUES (1)")

        // Opening without key should fail
        #expect(throws: SQLiteError.self) {
            let _ = try SQLCipher(path: path)
        }

        // Opening with correct key should succeed
        let db2 = try SQLCipher(path: path, key: "secret")
        let result = try db2.reader.execute("SELECT COUNT(*) as cnt FROM test")
        #expect(result.first?["cnt"].flatMap { Int(sqliteValue: $0) } == 1)
    }

    @Test func testCreatePlaintextDatabase() throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        #expect(db.isEncrypted == false)

        try db.writer.exec("CREATE TABLE test (id INTEGER PRIMARY KEY)")
        try db.writer.exec("INSERT INTO test (id) VALUES (1)")

        let db2 = try SQLCipher(path: path)
        let result = try db2.reader.execute("SELECT COUNT(*) as cnt FROM test")
        #expect(result.first?["cnt"].flatMap { Int(sqliteValue: $0) } == 1)
    }

    @Test func testRekeyEncryptedDatabase() throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path, key: "original")
        try db.writer.exec("CREATE TABLE test (id INTEGER PRIMARY KEY)")
        try db.writer.exec("INSERT INTO test (id) VALUES (42)")

        try db.resetKey(to: "new-key")
        #expect(db.isEncrypted == true)

        // Old key should fail
        #expect(throws: SQLiteError.self) {
            let _ = try SQLCipher(path: path, key: "original")
        }

        // New key should work
        let db2 = try SQLCipher(path: path, key: "new-key")
        let result = try db2.reader.execute("SELECT COUNT(*) as cnt FROM test")
        #expect(result.first?["cnt"].flatMap { Int(sqliteValue: $0) } == 1)
    }

    @Test func testEncryptExistingPlaintextDatabase() throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        #expect(db.isEncrypted == false)
        try db.writer.exec("CREATE TABLE test (id INTEGER PRIMARY KEY)")
        try db.writer.exec("INSERT INTO test (id) VALUES (99)")

        try db.resetKey(to: "secret")
        #expect(db.isEncrypted == true)

        // Opening without key should now fail
        #expect(throws: SQLiteError.self) {
            let _ = try SQLCipher(path: path)
        }

        // Opening with key should succeed and preserve data
        let db2 = try SQLCipher(path: path, key: "secret")
        let result = try db2.reader.execute("SELECT COUNT(*) as cnt FROM test")
        #expect(result.first?["cnt"].flatMap { Int(sqliteValue: $0) } == 1)
    }

    @Test func testDecryptExistingEncryptedDatabase() throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path, key: "secret")
        try db.writer.exec("CREATE TABLE test (id INTEGER PRIMARY KEY)")
        try db.writer.exec("INSERT INTO test (id) VALUES (77)")

        try db.resetKey(to: nil)
        #expect(db.isEncrypted == false)

        // Opening with key should now fail
        #expect(throws: SQLiteError.self) {
            let _ = try SQLCipher(path: path, key: "secret")
        }

        // Opening without key should succeed and preserve data
        let db2 = try SQLCipher(path: path)
        let result = try db2.reader.execute("SELECT COUNT(*) as cnt FROM test")
        #expect(result.first?["cnt"].flatMap { Int(sqliteValue: $0) } == 1)
    }

    @Test func testPlaintextToPlaintextIsNoOp() throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        try db.writer.exec("CREATE TABLE test (id INTEGER PRIMARY KEY)")

        try db.resetKey(to: nil)
        try db.resetKey(to: "")
        #expect(db.isEncrypted == false)

        let db2 = try SQLCipher(path: path)
        let result = try db2.reader.execute("SELECT COUNT(*) as cnt FROM test")
        #expect(result.first?["cnt"].flatMap { Int(sqliteValue: $0) } == 0)
    }

    @Test func testInMemoryDatabaseMigrationThrows() throws {
        let db = try SQLCipher(path: ":memory:")
        try db.writer.exec("CREATE TABLE test (id INTEGER PRIMARY KEY)")

        #expect(throws: SQLiteError.self) {
            try db.resetKey(to: "secret")
        }
    }
}
