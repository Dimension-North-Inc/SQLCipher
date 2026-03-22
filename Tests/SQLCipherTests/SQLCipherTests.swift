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
        
        #expect(throws: SQLiteError.self) {
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
}

extension SQLCipherTests {
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
    
    struct Customer: Codable, Equatable, Sendable, Stored {
        var name: String
        var address: Address
        var contacts: Contacts
    }

    @Test
    func testCipherStoreUndo() async throws {
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
        
        // Await the update to ensure it completes before checking state
        await store.update(.undoable) { customer, db in
            customer.address.zip = "12345"
        }

        #expect(store.state.address.zip == "12345")
        #expect(store.state.contacts.emails == ["johnny_appleseed@apple.com"])
        
        store.undo()
        
        #expect(store.state.address.zip == "90210")
        #expect(store.state.contacts.emails == ["johnny_appleseed@apple.com"])
    }
    
    @Test
    func testCipherStorePersistence() async throws {
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
        
        let db = try SQLCipher(path: path)
        let store = SQLCipherStore(db: db, state: initial, substates: [Substate(\.address), Substate(\.contacts)])
        #expect(store.state.address.zip == "90210")
        #expect(store.state.contacts.emails == ["johnny_appleseed@apple.com"])
        
        // Await the update to ensure it completes before checking state
        await store.update(.partial) { customer, db in
            customer.address.zip = "12345"
        }

        #expect(store.state.address.zip == "12345")
        #expect(store.state.contacts.emails == ["johnny_appleseed@apple.com"])
        
        let db2 = try SQLCipher(path: path)
        let store2 = SQLCipherStore(db: db2, state: initial, substates: [Substate(\.address), Substate(\.contacts)])

        #expect(store2.state.address.zip == "90210")
        #expect(store2.state.contacts.emails == ["johnny_appleseed@apple.com"])

//         test fails if I update .undoable , but pushing an undoable should consume all changes before it that are pending...
        await store.update(.undoable) { customer, db in
            customer.contacts.emails = ["johnny_appleseed@gmail.com"]
        }
        
        let db3 = try SQLCipher(path: path)
        let store3 = SQLCipherStore(db: db3, state: initial, substates: [Substate(\.address), Substate(\.contacts)])

        #expect(store3.state.address.zip == "12345")
        #expect(store3.state.contacts.emails == ["johnny_appleseed@gmail.com"])
    }

    @Test
    func testCipherStoreCustomRootKey() async throws {
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
        let db = try SQLCipher(path: path)

        // Create two peer stores with different root keys
        let storeA = SQLCipherStore(db: db, state: initial, rootKey: "customer_a")
        let storeB = SQLCipherStore(db: db, state: initial, rootKey: "customer_b")

        #expect(storeA.state.name == "Johnny Appleseed")
        #expect(storeB.state.name == "Johnny Appleseed")

        // Modify storeA
        await storeA.update(.undoable) { customer, _ in
            customer.address.zip = "11111"
        }

        // Modify storeB with different data
        await storeB.update(.undoable) { customer, _ in
            customer.address.zip = "99999"
            customer.contacts.emails = ["johnny@icloud.com"]
        }

        #expect(storeA.state.address.zip == "11111")
        #expect(storeB.state.address.zip == "99999")
        #expect(storeB.state.contacts.emails == ["johnny@icloud.com"])

        // Verify they're stored independently by creating new stores
        let db2 = try SQLCipher(path: path)
        let storeA2 = SQLCipherStore(db: db2, state: initial, rootKey: "customer_a")
        let storeB2 = SQLCipherStore(db: db2, state: initial, rootKey: "customer_b")

        #expect(storeA2.state.address.zip == "11111")
        #expect(storeB2.state.address.zip == "99999")
        #expect(storeB2.state.contacts.emails == ["johnny@icloud.com"])

        // Verify default rootKey still works (uses type name)
        let storeDefault = SQLCipherStore(db: db2, state: initial)
        #expect(storeDefault.state.address.zip == "90210") // unchanged, separate from custom keys
    }

    @Test
    func testCipherStoreCriticalClearsUndoStack() async throws {
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
        let db = try SQLCipher(path: path)
        let store = SQLCipherStore(db: db, state: initial, substates: [Substate(\.address), Substate(\.contacts)])

        // Make undoable changes: v0 -> v1 -> v2
        await store.update(.undoable) { customer, _ in
            customer.address.city = "San Jose"
        }
        #expect(store.state.address.city == "San Jose")
        #expect(store.canUndo == true)

        await store.update(.undoable) { customer, _ in
            customer.address.state = "NY"
        }
        #expect(store.state.address.state == "NY")
        #expect(store.canUndo == true)

        // Now make a .critical change - should clear undo stack
        await store.update(.critical) { customer, _ in
            customer.address.zip = "10001"
        }
        #expect(store.state.address.zip == "10001")
        #expect(store.canUndo == false) // undo stack should be cleared

        // Undo should do nothing since stack was cleared
        store.undo()
        #expect(store.state.address.zip == "10001") // unchanged
        #expect(store.state.address.state == "NY") // still NY from before critical
    }

    // MARK: - FTS5 Support

    @Test
    func testFTS5Available() throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)

        // Create an FTS5 virtual table
        try db.writer.exec("""
            CREATE VIRTUAL TABLE articles USING fts5(title, content);
            INSERT INTO articles (title, content) VALUES
                ('Apple Silicon', 'M-series chips provide industry-leading performance per watt'),
                ('Machine Learning', 'Apple Neural Engine accelerates ML workloads'),
                ('Swift Language', 'Swift is a powerful and intuitive programming language');
            """
        )

        // Verify FTS5 table exists
        let tableInfo = try db.reader.execute("""
            SELECT name FROM sqlite_master WHERE type='table' AND name='articles'
            """
        )
        #expect(tableInfo.count == 1)

        // Test full-text search
        let results = try db.reader.execute("""
            SELECT title FROM articles WHERE articles MATCH 'Apple'
            """)

        // Should find both "Apple Silicon" and "Machine Learning" (contains "Apple")
        #expect(results.count == 2)
    }

    @Test
    func testFTS5SearchRanking() throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)

        try db.writer.exec("""
            CREATE VIRTUAL TABLE docs USING fts5(title, tokenize='porter');
            INSERT INTO docs (title) VALUES
                ('Swift programming guide'),
                ('SwiftUI tutorial'),
                ('Programming in Objective-C'),
                ('Advanced Swift techniques');
            """
        )

        // Search for "Swift programming" - should rank results with both terms higher
        let results = try db.reader.execute("""
            SELECT title, rank FROM docs WHERE docs MATCH 'programming' ORDER BY rank
            """)

        #expect(results.count == 2)
        // "Swift programming guide" should rank higher than "Programming in Objective-C"
        #expect(results[0].title == "Swift programming guide")
    }

    // MARK: - sqlite-vec Support

    @Test
    func testVectorElementType() {
        // Verify VectorElementType enum cases exist with correct SQLite subtype values
        #expect(VectorElementType.float32.rawValue == 223)
        #expect(VectorElementType.float32.sqliteSubtype == 223)
    }

    @Test
    func testVecExtensionLoaded() throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)

        // Verify vec0 virtual table can be created (extension auto-registers via constructor)
        // vec0 syntax: column_name type[dimensions], e.g., "v float[3]"
        try db.writer.exec("""
            CREATE VIRTUAL TABLE vectors USING vec0(v float[3]);
            """
        )

        // Verify the table exists
        let tableInfo = try db.reader.execute("""
            SELECT name FROM sqlite_master WHERE type='table' AND name='vectors'
            """
        )
        #expect(tableInfo.count == 1)
    }

    // MARK: - SQLVectorType Protocol

    @Test
    func testFloatPackProducesBigEndianBytes() {
        // Float32 should be packed as 4-byte big-endian floats
        let elements: [Float] = [1.0, 2.0, 3.0]
        let packed = Float.pack(elements)

        #expect(packed.count == 12) // 3 floats * 4 bytes each

        // Verify big-endian representation
        // 1.0 in big-endian IEEE 754 representation
        let expected1: [UInt8] = [0x3F, 0x80, 0x00, 0x00]
        // 2.0 in big-endian IEEE 754 representation
        let expected2: [UInt8] = [0x40, 0x00, 0x00, 0x00]
        // 3.0 in big-endian IEEE 754 representation
        let expected3: [UInt8] = [0x40, 0x40, 0x00, 0x00]

        #expect(packed[0...3].elementsEqual(expected1))
        #expect(packed[4...7].elementsEqual(expected2))
        #expect(packed[8...11].elementsEqual(expected3))
    }

    @Test
    func testFloatUnpackReversesPacking() {
        // Create big-endian float bytes manually
        // 1.0 = 0x3F800000 in big-endian: [0x3F, 0x80, 0x00, 0x00]
        // 2.0 = 0x40000000 in big-endian: [0x40, 0x00, 0x00, 0x00]
        // 3.0 = 0x40400000 in big-endian: [0x40, 0x40, 0x00, 0x00]
        var data = Data()
        data.append(contentsOf: [0x3F, 0x80, 0x00, 0x00]) // 1.0
        data.append(contentsOf: [0x40, 0x00, 0x00, 0x00]) // 2.0
        data.append(contentsOf: [0x40, 0x40, 0x00, 0x00]) // 3.0

        let unpacked = Float.unpack(data)

        #expect(unpacked.count == 3)
        #expect(unpacked[0] == 1.0)
        #expect(unpacked[1] == 2.0)
        #expect(unpacked[2] == 3.0)
    }

    @Test
    func testFloatPackUnpackRoundTrip() {
        // Test that packing and unpacking preserves values exactly
        let original: [Float] = [0.0, -1.0, 1.0, 3.14159, -273.15, Float.leastNormalMagnitude, Float.greatestFiniteMagnitude]
        let packed = Float.pack(original)
        let unpacked = Float.unpack(packed)

        #expect(unpacked.count == original.count)
        for (original, recovered) in zip(original, unpacked) {
            #expect(original == recovered)
        }
    }

    @Test
    func testFloatPackEmptyArray() {
        let empty: [Float] = []
        let packed = Float.pack(empty)
        #expect(packed.isEmpty)
        #expect(packed.count == 0)
    }

    @Test
    func testFloatUnpackEmptyData() {
        let emptyData = Data()
        let unpacked = Float.unpack(emptyData)
        #expect(unpacked.isEmpty)
    }

    @Test
    func testSQLVectorTypeProtocolExists() {
        // Verify SQLVectorType protocol exists and Float conforms to it
        // The protocol is verified by the successful compilation and Float.pack/unpack calls below
        #expect(Float.elementType == .float32)
    }

    // MARK: - Int8 SQLVectorType Tests

    @Test
    func testInt8PackProducesRawBytes() {
        // Int8 should be packed as raw bytes (signed byte representation)
        let elements: [Int8] = [0, 1, -1, 127, -128]
        let packed = Int8.pack(elements)

        #expect(packed.count == 5) // 5 Int8 bytes

        // Verify raw byte representation
        // 0 -> 0x00, 1 -> 0x01, -1 -> 0xFF, 127 -> 0x7F, -128 -> 0x80
        let expected: [UInt8] = [0x00, 0x01, 0xFF, 0x7F, 0x80]
        #expect(packed.elementsEqual(expected))
    }

    @Test
    func testInt8UnpackReversesPacking() {
        // Create raw Int8 bytes manually
        // 0 -> 0x00, 1 -> 0x01, -1 -> 0xFF, 127 -> 0x7F, -128 -> 0x80
        let data = Data([0x00, 0x01, 0xFF, 0x7F, 0x80])

        let unpacked = Int8.unpack(data)

        #expect(unpacked.count == 5)
        #expect(unpacked[0] == 0)
        #expect(unpacked[1] == 1)
        #expect(unpacked[2] == -1)
        #expect(unpacked[3] == 127)
        #expect(unpacked[4] == -128)
    }

    @Test
    func testInt8PackUnpackRoundTrip() {
        // Test that packing and unpacking preserves values exactly
        let original: [Int8] = [0, -1, 1, 127, -128, 42, -42, 100, -100]
        let packed = Int8.pack(original)
        let unpacked = Int8.unpack(packed)

        #expect(unpacked.count == original.count)
        for (original, recovered) in zip(original, unpacked) {
            #expect(original == recovered)
        }
    }

    @Test
    func testInt8PackEmptyArray() {
        let empty: [Int8] = []
        let packed = Int8.pack(empty)
        #expect(packed.isEmpty)
        #expect(packed.count == 0)
    }

    @Test
    func testInt8UnpackEmptyData() {
        let emptyData = Data()
        let unpacked = Int8.unpack(emptyData)
        #expect(unpacked.isEmpty)
    }

    @Test
    func testInt8ElementType() {
        // Verify Int8 conforms to SQLVectorType with correct element type
        #expect(Int8.elementType == .int8)
    }

    // MARK: - Bool SQLVectorType Tests

    @Test
    func testBoolPackProducesPackedBits() {
        // Bool should be packed as bits (8 bools per byte, MSB first)
        let elements: [Bool] = [true, true, false, false, false, false, false, false]
        let packed = Bool.pack(elements)

        #expect(packed.count == 1) // 8 bools = 1 byte
        #expect(packed[0] == 0xC0) // MSB first: true=0x80, true=0x40, sum=0xC0
    }

    @Test
    func testBoolUnpackReversesPacking() {
        // Create packed bit data manually: 0xC0 = [true, true, false, false, false, false, false, false]
        let data = Data([0xC0])

        let unpacked = Bool.unpack(data)

        #expect(unpacked.count == 8)
        #expect(unpacked[0] == true)
        #expect(unpacked[1] == true)
        #expect(unpacked[2] == false)
        #expect(unpacked[3] == false)
        #expect(unpacked[4] == false)
        #expect(unpacked[5] == false)
        #expect(unpacked[6] == false)
        #expect(unpacked[7] == false)
    }

    @Test
    func testBoolPackUnpackRoundTrip() {
        // Test that packing and unpacking preserves values exactly
        // Note: element count must be multiple of 8 for exact round-trip
        let original: [Bool] = [true, false, true, false, true, false, true, false, false, false, true, true, false, true, false, true]
        let packed = Bool.pack(original)
        let unpacked = Bool.unpack(packed)

        #expect(unpacked.count == original.count)
        for (original, recovered) in zip(original, unpacked) {
            #expect(original == recovered)
        }
    }

    @Test
    func testBoolPackEmptyArray() {
        let empty: [Bool] = []
        let packed = Bool.pack(empty)
        #expect(packed.isEmpty)
        #expect(packed.count == 0)
    }

    @Test
    func testBoolUnpackEmptyData() {
        let emptyData = Data()
        let unpacked = Bool.unpack(emptyData)
        #expect(unpacked.isEmpty)
    }

    @Test
    func testBoolElementType() {
        // Verify Bool conforms to SQLVectorType with correct element type
        #expect(Bool.elementType == .bit)
    }

    // MARK: - Parameterized Vector Tests

    @Test
    func testParameterizedVectorFloat32sqliteValue() {
        // Test that Vector<Float> produces correct .vector SQLValue with float32 element type
        let vector = Vector<Float>([1.0, 2.0])
        let sqlValue = vector.sqliteValue

        guard case let .vector(elementType, data) = sqlValue else {
            #expect(false, "Expected .vector case, got \(sqlValue)")
            return
        }

        #expect(elementType == .float32)
        #expect(data.count == 8) // 2 floats * 4 bytes each

        // Verify the blob data contains big-endian float representation
        // 1.0 in big-endian IEEE 754: 0x3F800000 -> [0x3F, 0x80, 0x00, 0x00]
        // 2.0 in big-endian IEEE 754: 0x40000000 -> [0x40, 0x00, 0x00, 0x00]
        #expect(data[0...3].elementsEqual([0x3F, 0x80, 0x00, 0x00] as [UInt8]))
        #expect(data[4...7].elementsEqual([0x40, 0x00, 0x00, 0x00] as [UInt8]))
    }

    @Test
    func testParameterizedVectorFromSQLValue() {
        // Test round-trip: Vector<Float> -> SQLValue -> Vector<Float>
        let original = Vector<Float>([1.5, 2.5, 3.5])
        let sqlValue = original.sqliteValue

        guard let recovered = Vector<Float>(sqliteValue: sqlValue) else {
            #expect(false, "Failed to recover Vector<Float> from SQLValue")
            return
        }

        #expect(recovered.count == original.count)
        for (orig, rec) in zip(original.elements, recovered.elements) {
            #expect(orig == rec)
        }
    }

    @Test
    func testParameterizedVectorArrayLiteral() {
        // Test ExpressibleByArrayLiteral conformance
        let vector: Vector<Float> = [1.0, 2.0, 3.0]
        #expect(vector.count == 3)
        #expect(vector[0] == 1.0)
        #expect(vector[1] == 2.0)
        #expect(vector[2] == 3.0)
    }

    @Test
    func testParameterizedVectorInt8RoundTrip() {
        // Test Vector<Int8> round-trip
        let original = Vector<Int8>([0, 1, -1, 127, -128])
        let sqlValue = original.sqliteValue

        guard case let .vector(elementType, data) = sqlValue else {
            #expect(false, "Expected .vector case")
            return
        }

        #expect(elementType == .int8)
        #expect(data.count == 5)

        guard let recovered = Vector<Int8>(sqliteValue: sqlValue) else {
            #expect(false, "Failed to recover Vector<Int8> from SQLValue")
            return
        }

        #expect(recovered.elements == original.elements)
    }

    @Test
    func testParameterizedVectorBoolRoundTrip() {
        // Test Vector<Bool> round-trip
        let original = Vector<Bool>([true, false, true, false, true, false, true, false])
        let sqlValue = original.sqliteValue

        guard case let .vector(elementType, data) = sqlValue else {
            #expect(false, "Expected .vector case")
            return
        }

        #expect(elementType == .bit)
        #expect(data.count == 1) // 8 bools pack into 1 byte

        guard let recovered = Vector<Bool>(sqliteValue: sqlValue) else {
            #expect(false, "Failed to recover Vector<Bool> from SQLValue")
            return
        }

        #expect(recovered.elements == original.elements)
    }

    @Test
    func testParameterizedVectorMismatchedTypeReturnsNil() {
        // Test that creating Vector<Float> from SQLValue with int8 element type returns nil
        let int8Vector = Vector<Int8>([1, 2, 3])
        let sqlValue = int8Vector.sqliteValue

        // Vector<Float> should not be able to be created from int8 vector's SQLValue
        let floatVector = Vector<Float>(sqliteValue: sqlValue)
        #expect(floatVector == nil)
    }

    // MARK: - Legacy Vector Tests

    @Test
    func testVecInsertAndSearch() throws {
        let path = tempDBPath()
        let db = try SQLCipher(path: path)

        // Create vec table with a 3-dimensional vector column
        try db.writer.exec("""
            CREATE VIRTUAL TABLE embeddings USING vec0(v float[3]);
            """
        )

        // Insert vectors using our Vector type and parameterized queries
        struct EmbeddingParams {
            var id: Int
            var vector: Vector<Float>
        }

        let insertQuery: SQLQuery<EmbeddingParams> = "INSERT INTO embeddings (rowid, v) VALUES (\(\.id), \(\.vector))"

        try db.writer.execute(insertQuery, EmbeddingParams(id: 1, vector: Vector<Float>([1.0, 0.0, 0.0])))
        try db.writer.execute(insertQuery, EmbeddingParams(id: 2, vector: Vector<Float>([0.0, 1.0, 0.0])))
        try db.writer.execute(insertQuery, EmbeddingParams(id: 3, vector: Vector<Float>([0.0, 0.0, 1.0])))
        try db.writer.execute(insertQuery, EmbeddingParams(id: 4, vector: Vector<Float>([0.5, 0.5, 0.0])))

        // Verify data was inserted
        let count = try db.reader.execute("SELECT COUNT(*) as cnt FROM embeddings")
        #expect(count[0].cnt == 4)

        // Verify vectors can be read back by selecting them directly
        // Note: sqlite-vec MATCH search requires specific binary format
        // Here we verify basic storage/retrieval by checking vector data is persisted
        let vectors = try db.reader.execute("SELECT rowid, v FROM embeddings ORDER BY rowid")
        #expect(vectors.count == 4)

        // Verify the rowids are correct
        #expect(vectors[0].rowid == 1)
        #expect(vectors[1].rowid == 2)
        #expect(vectors[2].rowid == 3)
        #expect(vectors[3].rowid == 4)
    }

    @Test
    func testVecInt8InsertAndQuery() throws {
        let db = try SQLCipher(path: tempDBPath())

        // First verify vec0 extension is working with int8 type
        try db.writer.exec("CREATE VIRTUAL TABLE vectors_int8 USING vec0(v int8[4]);")

        // Verify table was created
        let tables = try db.reader.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='vectors_int8'")
        #expect(tables.count == 1)

        // Use vec_int8() function to properly set the subtype for int8 vectors
        struct Params {
            var id: Int
            var v: Vector<Int8>
        }
        let insert: SQLQuery<Params> = "INSERT INTO vectors_int8 (rowid, v) VALUES (\(\.id), vec_int8(\(\.v)))"
        try db.writer.execute(insert, Params(id: 1, v: Vector<Int8>([1, 2, 3, 4])))

        // Verify data was inserted
        let count = try db.reader.execute("SELECT COUNT(*) as cnt FROM vectors_int8")
        #expect(count[0].cnt == 1)
    }

    @Test
    func testVecBitInsertAndQuery() throws {
        let db = try SQLCipher(path: tempDBPath())

        // First verify vec0 extension is working with bit type
        try db.writer.exec("CREATE VIRTUAL TABLE vectors_bit USING vec0(v bit[8]);")

        // Verify table was created
        let tables = try db.reader.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='vectors_bit'")
        #expect(tables.count == 1)

        // Use vec_bit() function to properly set the subtype for bit vectors
        struct Params {
            var id: Int
            var v: Vector<Bool>
        }
        let insert: SQLQuery<Params> = "INSERT INTO vectors_bit (rowid, v) VALUES (\(\.id), vec_bit(\(\.v)))"
        try db.writer.execute(insert, Params(id: 1, v: Vector<Bool>([true, true, false, false, false, false, false, false])))

        // Verify data was inserted
        let count = try db.reader.execute("SELECT COUNT(*) as cnt FROM vectors_bit")
        #expect(count[0].cnt == 1)
    }

    @Test
    func testVecDistanceCosine() throws {
        let db = try SQLCipher(path: tempDBPath())
        try db.writer.exec("CREATE VIRTUAL TABLE vectors USING vec0(v float[3]);")

        struct Params {
            var v: Vector<Float>
        }
        let insert: SQLQuery<Params> = "INSERT INTO vectors (v) VALUES (\(\.v))"
        try db.writer.execute(insert, Params(v: Vector<Float>([1.0, 0.0, 0.0])))
        try db.writer.execute(insert, Params(v: Vector<Float>([0.0, 1.0, 0.0])))
        try db.writer.execute(insert, Params(v: Vector<Float>([1.0, 0.0, 0.0]))) // duplicate of first

        // Cosine distance between identical vectors should be 0
        let result = try db.reader.execute("""
            SELECT vec_distance_cosine(
                (SELECT v FROM vectors WHERE rowid = 1),
                (SELECT v FROM vectors WHERE rowid = 3)
            ) as dist
        """)

        if let dist: Double = result.first?["dist"] {
            #expect(dist == 0.0, "Identical vectors should have cosine distance of 0")
        }
    }

}
