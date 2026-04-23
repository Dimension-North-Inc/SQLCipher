//
//  SQLCipherStoreErrorTests.swift
//  SQLCipherTests
//
//  Created by Kimi on 4/23/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import Testing
import Foundation
@testable import SQLCipher

@Suite struct SQLCipherStoreErrorTests {
    struct SimpleState: Codable, Equatable, Sendable, Stored {
        var counter: Int
    }

    func tempDBPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("db")
            .path
    }

    @Test func testUpdateErrorRollsBackTransaction() async throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        let store = SQLCipherStore(db: db, state: SimpleState(counter: 0))

        // First, make a successful persisted change
        await store.update(.undoable) { state, _ in
            state.counter = 10
        }
        #expect(store.state.counter == 10)

        // Then attempt an update that throws
        let result = await store.update(.undoable) { state, conn in
            state.counter = 20
            throw NSError(domain: "TestError", code: 1)
        }
        #expect(result == nil)
        #expect(store.error != nil)

        // State should be reverted to 10 (not 20)
        #expect(store.state.counter == 10)

        // Verify persistence wasn't corrupted
        let db2 = try SQLCipher(path: path)
        let store2 = SQLCipherStore(db: db2, state: SimpleState(counter: 0))
        #expect(store2.state.counter == 10)
    }

    @Test func testTryUpdatePropagatesError() async throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        let store = SQLCipherStore(db: db, state: SimpleState(counter: 0))

        await store.update(.undoable) { state, _ in
            state.counter = 5
        }

        await #expect(throws: NSError.self) {
            try await store.tryUpdate(.undoable) { state, _ in
                state.counter = 99
                throw NSError(domain: "TestError", code: 42)
            }
        }

        // State should remain 5 after failed update
        #expect(store.state.counter == 5)
    }

    @Test func testDispatchAction() async throws {
        struct IncrementAction: SQLAction {
            typealias State = SimpleState
            var type: UpdateType { .undoable }
            func update(state: inout SimpleState, db: SQLConnection) throws {
                state.counter += 1
            }
        }

        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        let store = SQLCipherStore(db: db, state: SimpleState(counter: 0))

        await store.dispatch(IncrementAction())
        #expect(store.state.counter == 1)

        await store.dispatch(IncrementAction())
        #expect(store.state.counter == 2)

        store.undo()
        #expect(store.state.counter == 1)
    }

    @Test func testDispatchCriticalAction() async throws {
        struct ResetAction: SQLAction {
            typealias State = SimpleState
            var type: UpdateType { .critical }
            func update(state: inout SimpleState, db: SQLConnection) throws {
                state.counter = 0
            }
        }

        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        let store = SQLCipherStore(db: db, state: SimpleState(counter: 0))

        await store.update(.undoable) { state, _ in state.counter = 10 }
        await store.update(.undoable) { state, _ in state.counter = 20 }
        #expect(store.canUndo == true)

        await store.dispatch(ResetAction())
        #expect(store.state.counter == 0)
        #expect(store.canUndo == false)
    }

    @Test func testDatabaseOperationInUpdate() async throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        let store = SQLCipherStore(db: db, state: SimpleState(counter: 0))

        await store.update(.undoable) { state, conn in
            state.counter = 5
            try conn.exec("CREATE TABLE events (id INTEGER PRIMARY KEY)")
            try conn.exec("INSERT INTO events (id) VALUES (\(state.counter))")
        }

        let result = try db.reader.execute("SELECT COUNT(*) as cnt FROM events")
        #expect(result.first?["cnt"].flatMap { Int(sqliteValue: $0) } == 1)
    }

    @Test func testErrorInDatabaseOperationRollsBack() async throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        let store = SQLCipherStore(db: db, state: SimpleState(counter: 0))

        await store.update(.undoable) { state, conn in
            state.counter = 5
            try conn.exec("CREATE TABLE events (id INTEGER PRIMARY KEY)")
        }

        // This update should fail because it references a non-existent table
        let result = await store.update(.undoable) { state, conn in
            state.counter = 10
            try conn.exec("INSERT INTO nonexistent_table (id) VALUES (1)")
        }
        #expect(result == nil)

        // State should remain 5, not 10
        #expect(store.state.counter == 5)

        // The events table should still exist (not rolled back)
        let tableInfo = try db.reader.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='events'")
        #expect(tableInfo.count == 1)
    }
}
