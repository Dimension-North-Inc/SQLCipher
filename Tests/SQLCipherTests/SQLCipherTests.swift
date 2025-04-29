//
//  SQLCipherTests.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 2/9/25.
//

import Testing
import Foundation

@testable
import SQLCipher

@Suite struct SQLCipherTests {
    func tempDBPath() -> String {
        let temp = FileManager.default.temporaryDirectory
        let path = temp.appending(path: UUID().uuidString).path(percentEncoded: false)
        
        return path
    }

    @Test func testDatabaseEncryption() throws {
        let correctPassword = "correct_password"
        let incorrectPassword = "incorrect_password"
        
        let path = tempDBPath()
        let db = try SQLCipher(path: path, key: correctPassword)
        
        try db.writer.exec("""
            CREATE TABLE test (id INTEGER PRIMARY KEY, title TEXT);
            INSERT INTO test (id, title) VALUES (1, "test");
            """
        )
        
        #expect(throws: SQLError.self) {
            let _ = try SQLCipher(path: path, key: incorrectPassword)
        }
        
        #expect(throws: Never.self) {
            let db = try SQLCipher(path: path, key: correctPassword)
            let result = try db.reader.execute("SELECT title FROM test WHERE id = \(1)")

            #expect(result.count == 1)
            #expect(result[0].title == "test")
        }
    }
    
    @Test func testQueryBuilder() {
        struct User {
            var id: Int
            var name: String
        }
        
        let query = SQLQuery<User> {
            "SELECT name FROM user WHERE id ="
            param(\.id)
        }
        
        #expect(query.sql == "SELECT name FROM user WHERE id = :p1")
        
        let user = User(id: 1, name: "johnny.appleseed@apple.com")
        #expect(query.params(from: user) == ["p1": .integer(1)])
    }

    @Test func testCipherStorePersistence() throws {
        struct Address: Codable, Equatable, Stored {
            var street: String
            var city: String
            var state: String
            var zip: String
        }
        
        struct Contacts: Codable, Equatable, Stored {
            var emails: [String]
            var phoneNumbers: [String]
        }
        
        struct Customer: Equatable {
            var name: String
            var address: Address
            var contacts: Contacts
        }
        
        let initial = Customer(
            name: "Johnny Appleseed",
            address: Address(
                street: "1 Infinite Loop",
                city: "Cupertino",
                state: "CA",
                zip: "90210"
            ),
            contacts: Contacts(
                emails: ["johnny_appleseed@apple.com"],
                phoneNumbers: []
            )
        )
        
        let path = tempDBPath()
        let db   = try SQLCipher(path: path)

        let store = SQLCipherStore(db: db, state: initial, substates: [Substate(\.address), Substate(\.contacts)])
        #expect(store.state.address.zip == "90210")
        #expect(store.state.contacts.emails == ["johnny_appleseed@apple.com"])
        
        store.update(.undoable) { customer, db in
            customer.address.zip = "12345"
        }
        
        #expect(store.state.address.zip == "12345")
        #expect(store.state.contacts.emails == ["johnny_appleseed@apple.com"])

        let db2 = try SQLCipher(path: path)
        let store2 = SQLCipherStore(db: db2, state: initial, substates: [Substate(\.address), Substate(\.contacts)])

        #expect(store2.state.address.zip == "12345")
        #expect(store2.state.contacts.emails == ["johnny_appleseed@apple.com"])
    }
}
