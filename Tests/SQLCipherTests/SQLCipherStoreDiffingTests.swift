//
//  SQLCipherStoreDiffingTests.swift
//  SQLCipherTests
//
//  Created by Kimi on 4/23/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import Testing
import Foundation
@testable import SQLCipher

@Suite struct SQLCipherStoreDiffingTests {
    struct Address: Codable, Equatable, Stored {
        var street: String
        var city: String
        var state: String
        var zip: String
    }

    struct Preferences: Codable, Equatable, Stored {
        var theme: String
        var notifications: Bool
    }

    struct AppState: Codable, Equatable, Sendable, Stored {
        var name: String
        var address: Address
        var preferences: Preferences
    }

    final class StatementTrace {
        var statements: [String] = []
    }

    func tempDBPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("db")
            .path
    }

    func makeStore(db: SQLCipher) -> SQLCipherStore<AppState> {
        let initial = AppState(
            name: "Test",
            address: Address(street: "1 Loop", city: "Cupertino", state: "CA", zip: "90210"),
            preferences: Preferences(theme: "light", notifications: true)
        )
        return SQLCipherStore(db: db, state: initial, substates: [
            Substate(\.address),
            Substate(\.preferences)
        ])
    }

    @Test func testOnlyChangedSubstateIsPersisted() async throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        let store = makeStore(db: db)

        // Change only address
        await store.update(.undoable) { state, _ in
            state.address.zip = "10001"
        }

        // Verify in a new store that only address changed
        let db2 = try SQLCipher(path: path)
        let store2 = makeStore(db: db2)

        #expect(store2.state.address.zip == "10001")
        #expect(store2.state.preferences.theme == "light")
        #expect(store2.state.preferences.notifications == true)
        #expect(store2.state.name == "Test")
    }

    @Test func testMultipleSubstatesChangeTogether() async throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        let store = makeStore(db: db)

        await store.update(.undoable) { state, _ in
            state.address.city = "New York"
            state.preferences.theme = "dark"
        }

        let db2 = try SQLCipher(path: path)
        let store2 = makeStore(db: db2)

        #expect(store2.state.address.city == "New York")
        #expect(store2.state.preferences.theme == "dark")
    }

    @Test func testUnchangedSubstateIsNotOverwritten() async throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        let store = makeStore(db: db)

        // First change address
        await store.update(.undoable) { state, _ in
            state.address.zip = "11111"
        }

        // Then change preferences
        await store.update(.undoable) { state, _ in
            state.preferences.notifications = false
        }

        // Address should still be "11111" after the second update
        let db2 = try SQLCipher(path: path)
        let store2 = makeStore(db: db2)

        #expect(store2.state.address.zip == "11111")
        #expect(store2.state.preferences.notifications == false)
    }

    @Test func testCriticalUpdateWritesAllSubstates() async throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        let store = makeStore(db: db)

        await store.update(.critical) { state, _ in
            state.address.zip = "99999"
        }

        let db2 = try SQLCipher(path: path)
        let store2 = makeStore(db: db2)

        #expect(store2.state.address.zip == "99999")
        #expect(store2.state.preferences.theme == "light")
    }

    @Test func testUndoRestoresSubstate() async throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        let store = makeStore(db: db)

        await store.update(.undoable) { state, _ in
            state.address.zip = "55555"
        }
        #expect(store.state.address.zip == "55555")

        store.undo()
        #expect(store.state.address.zip == "90210")

        // Verify persistence after undo
        let db2 = try SQLCipher(path: path)
        let store2 = makeStore(db: db2)
        #expect(store2.state.address.zip == "90210")
    }

    @Test func testRedoRestoresSubstate() async throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        let store = makeStore(db: db)

        await store.update(.undoable) { state, _ in
            state.address.zip = "77777"
        }
        store.undo()
        store.redo()

        #expect(store.state.address.zip == "77777")

        let db2 = try SQLCipher(path: path)
        let store2 = makeStore(db: db2)
        #expect(store2.state.address.zip == "77777")
    }

    @Test func testPartialUpdateDoesNotPersist() async throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        let store = makeStore(db: db)

        await store.update(.partial) { state, _ in
            state.address.zip = "00000"
        }

        // Partial updates are in-memory only
        let db2 = try SQLCipher(path: path)
        let store2 = makeStore(db: db2)
        #expect(store2.state.address.zip == "90210")
    }

    @Test func testPartialUpdateDoesNotExecuteWriterTransactionStatements() async throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        let store = makeStore(db: db)
        let trace = StatementTrace()
        sqlite3_trace_v2(
            db.writer.db,
            UInt32(SQLITE_TRACE_STMT),
            { _, context, statement, _ in
                guard let context, let statement else {
                    return 0
                }

                let trace = Unmanaged<StatementTrace>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                let sql = sqlite3_sql(OpaquePointer(statement)).map(String.init(cString:)) ?? ""
                trace.statements.append(sql)
                return 0
            },
            Unmanaged.passUnretained(trace).toOpaque()
        )

        await store.update(.partial) { state, _ in
            state.address.zip = "00000"
        }

        #expect(store.state.address.zip == "00000")
        #expect(trace.statements.isEmpty)
    }

    @Test func testPartialUpdateReceivesReadOnlyDatabaseConnection() async throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)
        let store = makeStore(db: db)

        await #expect(throws: (any Error).self) {
            try await store.tryUpdate(.partial) { state, db in
                state.address.zip = "00000"
                try db.exec("CREATE TABLE partial_write_test (id INTEGER PRIMARY KEY)")
            }
        }

        #expect(store.state.address.zip == "90210")
    }
}
