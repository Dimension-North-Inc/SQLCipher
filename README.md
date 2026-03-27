# SQLCipher

A comprehensive Swift wrapper for SQLCipher that provides encrypted SQLite database functionality with two distinct usage patterns: standard database operations and a Redux-style state container powered by database-backed storage.

## Overview

This package delivers a robust Swift interface to SQLCipher, enabling developers to integrate encrypted SQLite databases into their iOS, macOS, watchOS, and tvOS applications. Beyond providing complete access to the SQLCipher C API through type-safe Swift interfaces, this package introduces an innovative Redux-style state management pattern where your application state is persisted directly to an encrypted database.

The package is designed with flexibility in mind, allowing developers to leverage either or both of its operating modes within a single application. Whether you need traditional database operations for complex queries and data relationships, or you prefer the predictability of Redux-style state management with automatic persistence, this package provides clean, well-documented APIs for both approaches.

## Requirements

| Platform | Minimum Version |
|----------|-----------------|
| iOS | 13.0 |
| macOS | 10.15 |
| watchOS | 6.0 |
| tvOS | 13.0 |

The package requires Swift 5.6 or later and depends on OpenSSL for cryptographic operations. All dependencies are managed through Swift Package Manager, simplifying integration and ensuring consistent builds across development machines and continuous integration environments.

## Installation

Swift Package Manager is the recommended integration method for this package. Add it to your project by selecting your target in Xcode, navigating to the Package Dependencies tab, and entering the repository URL:

```
https://github.com/Dimension-North-Inc/SQLCipher.git
```

Alternatively, you can add it programmatically to your Package.swift file:

```swift
dependencies: [
    .package(
        url: "https://github.com/Dimension-North-Inc/SQLCipher.git",
        from: "2.0.0"
    )
]
```

Then add the product to your target's dependencies:

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: ["SQLCipher"]
    )
]
```

## Security Considerations

The encryption provided by SQLCipher uses 256-bit AES in CBC mode by default, with a SHA-1 based HMAC for integrity verification. The encryption key you provide is never stored in the database; only the derived key material is retained. If you lose the key, your data is irrecoverably encrypted and cannot be accessed without it.

For production applications, consider how you will securely obtain and store the encryption key. Options include deriving the key from a user passphrase, retrieving it from a secure keychain, or using a hybrid approach where a keychain-stored master key encrypts per-database keys. Never hardcode keys in your application bundle, and consider using iOS/macOS Keychain services for key storage.

The state container stores your entire application state in the encrypted database. Be mindful of what information you include in state objects, as it will all be encrypted and persisted to disk. Sensitive data that should only be held in memory should not be included in the persisted state.

## Usage

This package provides two primary usage patterns: direct database operations and a Redux-style state container. The following sections demonstrate how to use each component.

### SQLCipher - Database Wrapper

`SQLCipher` is the main database wrapper that manages encrypted SQLite connections. It provides separate reader and writer connections for optimal concurrency.

```swift
import SQLCipher

// Initialize an encrypted database
let dbPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] + "/app.db"
let encryptionKey = "your-secure-encryption-key"
let db = try SQLCipher(path: dbPath, key: encryptionKey)

// Check if the database is encrypted
print("Database is encrypted: \(db.isEncrypted)")

// Change the encryption key (rekeying)
try db.resetKey(to: "new-encryption-key")

// Use an in-memory database (useful for testing)
let inMemoryDB = try SQLCipher(path: ":memory:")
```

### SQLConnection - Read and Write Operations

`SQLCipher` provides `reader` and `writer` connections. The reader connection supports concurrent reads, while the writer connection serializes writes.

```swift
// Execute raw SQL statements
try db.writer.exec("""
    CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        email TEXT UNIQUE,
        created_at TEXT
    )
""")

// Insert data
try db.writer.exec("""
    INSERT INTO users (name, email, created_at)
    VALUES ('Alice', 'alice@example.com', datetime('now'))
""")

// Query data using the reader connection (parameterized query)
struct EmailParam {
    let email: String
}

let query: SQLQuery<EmailParam> = "SELECT * FROM users WHERE email = \(\.email)"
let result = try db.reader.execute(query, EmailParam(email: "alice@example.com"))
for row in result {
    if let name: String = row["name"],
       let email: String = row["email"] {
        print("User: \(name) - \(email)")
    }
}

// Or use a static query without parameters
let allUsersQuery: SQLStaticQuery = "SELECT * FROM users"
let allUsers = try db.reader.execute(allUsersQuery)
for row in allUsers {
    if let name: String = row["name"],
       let email: String = row["email"] {
        print("User: \(name) - \(email)")
    }
}
```

### SQLQuery - Type-Safe Query Builder

`SQLQuery` provides a type-safe DSL for building parameterized SQL queries, preventing SQL injection and improving code clarity.

#### Using the DSL Builder

```swift
// Define a model for query parameters
struct UserParams {
    let id: Int
    let email: String
}

// Build a parameterized query using the DSL
let userQuery: SQLQuery<UserParams> = SQLQuery {
    "SELECT * FROM users WHERE id ="
    param(\.id)
    "AND email ="
    param(\.email, named: "email")
}

// Execute the query
let params = UserParams(id: 1, email: "alice@example.com")
let result = try db.reader.execute(userQuery, params)

// Access results using dynamic member lookup
for row in result {
    if let name: String = row.name,
       let email: String = row.email {
        print("Found user: \(name) - \(email)")
    }
}
```

#### Using String Interpolation

`SQLQuery` also supports string interpolation for simpler queries:

```swift
// Direct value interpolation
let count: Int = 42
let insertQuery: SQLStaticQuery = """
    INSERT INTO counter (count) VALUES (\(count))
"""

// Key path interpolation
struct Product {
    var id: UUID
    var name: String
    var price: Double
}

let product = Product(id: UUID(), name: "Widget", price: 19.99)
let productQuery: SQLQuery<Product> = """
    INSERT INTO products (id, name, price)
    VALUES (\(\.id), \(\.name), \(\.price))
"""

// Closure-based interpolation
let updateQuery: SQLQuery<Product> = """
    UPDATE products
    SET price = \({ $0.price * 1.1 })
    WHERE id = \(\.id)
"""
```

#### Complex Queries with Arrays

```swift
struct SearchParams {
    let userIds: [Int]
    let status: String
}

let searchQuery: SQLQuery<SearchParams> = SQLQuery {
    "SELECT * FROM orders WHERE user_id IN"
    param(\.userIds)
    "AND status ="
    param(\.status)
}

// The IN clause is automatically rewritten to use json_each
let params = SearchParams(userIds: [1, 2, 3, 4], status: "completed")
let results = try db.reader.execute(searchQuery, params)
```

#### Working with Query Results

```swift
let query: SQLStaticQuery = "SELECT id, name, email FROM users"
let result = try db.reader.execute(query)

// Access metadata
print("Rows returned: \(result.count)")
print("Affected rows: \(result.affectedRows)")
print("Last insert ID: \(result.lastInsertedRowID ?? -1)")

// Iterate over rows
for row in result {
    // Access by column name with type casting
    if let id: Int = row["id"],
       let name: String = row["name"],
       let email: String = row["email"] {
        print("User \(id): \(name) <\(email)>")
    }
    
    // Or use dynamic member lookup
    let id: Int? = row.id
    let name: String? = row.name
}
```

### Transactions

Use transactions to ensure atomicity of multiple operations:

```swift
try db.writer.begin()
do {
    try db.writer.exec("INSERT INTO users (name) VALUES ('Alice')")
    try db.writer.exec("INSERT INTO users (name) VALUES ('Bob')")
    try db.writer.commit()
} catch {
    try db.writer.rollback()
    throw error
}

// Savepoints for nested transactions
try db.writer.begin(savepoint: "sp1")
try db.writer.exec("INSERT INTO users (name) VALUES ('Charlie')")
try db.writer.commit(savepoint: "sp1")
```

### FTS5 - Full-Text Search

SQLCipher includes built-in support for FTS5 (Full-Text Search), enabling powerful text search capabilities:

```swift
// Create an FTS5 virtual table
try db.writer.exec("""
    CREATE VIRTUAL TABLE articles USING fts5(title, content, tokenize='porter');
    """)

// Insert content
try db.writer.exec("""
    INSERT INTO articles (title, content) VALUES
        ('Apple Silicon', 'M-series chips provide industry-leading performance'),
        ('Machine Learning', 'Apple Neural Engine accelerates ML workloads'),
        ('Swift Language', 'Swift is a powerful programming language');
    """)

// Full-text search using MATCH
let results = try db.reader.execute("""
    SELECT title, rank FROM articles WHERE articles MATCH 'Apple'
    ORDER BY rank
    """)
```

### Vector Search - Embedding Storage and Similarity

SQLCipher supports vector storage and similarity search via the sqlite-vec extension, automatically registered when the library is loaded.

#### The Vector Type

The `Vector` type wraps a `[Float]` array and conforms to `SQLValueRepresentable`, enabling seamless use with the query builder:

```swift
// Create vectors directly from array literals
let embedding = Vector([0.1, 0.5, -0.3, 0.8])

// Or from an array
let array: [Float] = [0.1, 0.5, -0.3, 0.8]
let embedding2 = Vector(array)
```

#### Creating a Vector Table

Create a virtual table with a vector column specifying the element type and dimensions:

```swift
// 384-dimensional float embeddings (common for embedding models)
try db.writer.exec("""
    CREATE VIRTUAL TABLE embeddings USING vec0(
        id INTEGER PRIMARY KEY,
        headline_embedding float[384]
    );
    """)
```

#### Inserting Vectors

Use parameterized queries with the `Vector` type:

```swift
struct EmbeddingParams {
    var id: Int
    var vector: Vector
}

let insertQuery: SQLQuery<EmbeddingParams> = """
    INSERT INTO embeddings (id, headline_embedding)
    VALUES (\(\.id), \(\.vector))
    """

try db.writer.execute(insertQuery, EmbeddingParams(id: 1, vector: Vector([0.1, 0.2, ...])))
try db.writer.execute(insertQuery, EmbeddingParams(id: 2, vector: Vector([0.5, 0.1, ...])))
```

#### Searching for Similar Vectors

Perform K-nearest-neighbors search using the MATCH operator with your query vector:

```swift
struct SearchParams {
    var query: Vector
}

let searchQuery: SQLQuery<SearchParams> = """
    SELECT id, distance FROM embeddings
    WHERE headline_embedding MATCH \(\.query) AND k = 5
    ORDER BY distance
    """

let queryEmbedding = Vector([0.1, 0.2, ...]) // Your search query
let results = try db.reader.execute(searchQuery, SearchParams(query: queryEmbedding))

for row in results {
    if let id: Int = row.id,
       let distance: Double = row.distance {
        print("ID: \(id), distance: \(distance)")
    }
}
```

#### Key Vector Functions

| Function | Description |
|----------|-------------|
| `vec_distance_cosine(a, b)` | Calculates cosine distance between vectors |
| `vec_distance_L2(a, b)` | Calculates Euclidean (L2) distance |
| `vec_normalize(vector)` | L2 normalization for Matryoshka embeddings |
| `vec_to_json(vector)` | Converts vector BLOB to readable JSON string |
| `vec_length(vector)` | Returns the number of dimensions |

### SQLCipherStore - State Container with Undo/Redo

`SQLCipherStore` provides a Redux-style state container with automatic persistence, undo/redo support, and command-style actions.

#### Basic State Management

```swift
import SQLCipher

// Define your state type (must conform to Stored, Equatable, and Codable)
struct AppState: Codable, Equatable, Stored {
    var counter: Int
    var userName: String
    var preferences: UserPreferences
}

struct UserPreferences: Codable, Equatable, Stored {
    var theme: String
    var notifications: Bool
}

// Initialize the store
let db = try SQLCipher(path: dbPath, key: encryptionKey)
let initialState = AppState(
    counter: 0,
    userName: "Guest",
    preferences: UserPreferences(theme: "light", notifications: true)
)

// Create store with automatic persistence of the entire state
let store = SQLCipherStore(db: db, state: initialState)

// Access state directly or via dynamic member lookup
print("Counter: \(store.state.counter)")
print("Counter: \(store.counter)")  // Same as above
```

#### Updating State

Updates are transactional and can be undoable, pending, critical, or partial:

```swift
// Undoable update - can be undone/redone
await store.update(.undoable) { state, db in
    state.counter += 1
    state.userName = "Alice"
}

// Pending update - persisted but part of a larger undoable group
await store.update(.pending) { state, db in
    state.preferences.theme = "dark"
}

// Critical update - forms a new baseline, cannot be undone
await store.update(.critical) { state, db in
    state.userName = "Administrator"
}

// Partial update - not persisted, part of an in-progress operation
await store.update(.partial) { state, db in
    state.counter += 1  // Temporary change
}

// Fire-and-forget update (doesn't await completion)
store.update(.undoable) { state, db in
    state.counter += 1
}

// Update with return value
let newCount = await store.update(.undoable) { state, db in
    state.counter += 1
    return state.counter
}
print("New count: \(newCount ?? 0)")

// Update with error handling
do {
    try await store.tryUpdate(.undoable) { state, db in
        if state.counter < 0 {
            throw NSError(domain: "InvalidState", code: 1)
        }
        state.counter += 1
        return state.counter
    }
} catch {
    print("Update failed: \(error)")
}
```

#### Undo/Redo Support

```swift
// Check if undo/redo is available
if store.canUndo {
    store.undo()
}

if store.canRedo {
    store.redo()
}

// Configure undo levels (default is 50)
store.levelsOfUndo = 100

// Example undo/redo workflow
await store.update(.undoable) { state, db in
    state.counter = 10
}

await store.update(.undoable) { state, db in
    state.counter = 20
}

print(store.counter)  // 20

store.undo()
print(store.counter)  // 10

store.undo()
print(store.counter)  // 0 (initial state)

store.redo()
print(store.counter)  // 10
```

#### Persistent Substates

For larger state objects, you can persist only specific substates independently:

```swift
struct AppState {
    var counter: Int  // Not persisted
    var address: Address  // Persisted as substate
    var contacts: Contacts  // Persisted as substate
}

struct Address: Codable, Equatable, Stored {
    var street: String
    var city: String
    var zip: String
}

struct Contacts: Codable, Equatable, Stored {
    var emails: [String]
    var phoneNumbers: [String]
}

// Create store with specific substates
let store = SQLCipherStore(
    db: db,
    state: initialState,
    substates: [
        Substate(\.address),
        Substate(\.contacts)
    ]
)

// Updates automatically persist only the changed substates
await store.update(.undoable) { state, db in
    state.address.zip = "90210"
    // Only address is persisted, counter changes are not
}
```

#### Custom Root Keys

You can specify a custom `key` parameter to namespace multiple stores, allowing independent state persistence within the same database:

```swift
// Two stores with different keys, each persisting entire state independently
let storeA = SQLCipherStore(db: db, key: "store_a", state: initialState)
let storeB = SQLCipherStore(db: db, key: "store_b", state: initialState)

// Each store maintains its own state under its respective key
```

You can also use custom keys with explicit substates:

```swift
let store = SQLCipherStore(
    db: db,
    key: "app1",
    state: initialState,
    substates: [
        Substate(\.address),
        Substate(\.contacts)
    ]
)
// Data is stored under keys "app1.address" and "app1.contacts"
```

#### Database Operations in State Updates

You can perform database operations within state update closures. All operations are part of the same transaction:

```swift
await store.update(.undoable) { state, db in
    // Update in-memory state
    state.counter += 1
    
    // Perform database operations using raw SQL
    // Note: String interpolation works directly with exec() for raw SQL
    try db.exec("""
        INSERT INTO events (counter_value, timestamp)
        VALUES (\(state.counter), datetime('now'))
    """)
    
    // Query related data using static queries
    let countQuery: SQLStaticQuery = "SELECT COUNT(*) as count FROM events"
    let result = try db.execute(countQuery)
    if let count: Int = result.first?.count {
        print("Total events: \(count)")
    }
    
    // Or use parameterized queries for reusable queries
    struct EventParams {
        let counter: Int
    }
    let insertQuery: SQLQuery<EventParams> = """
        INSERT INTO events (counter_value, timestamp)
        VALUES (\(\.counter), datetime('now'))
    """
    try db.execute(insertQuery, EventParams(counter: state.counter))
    
    // For raw SQL with dynamic values, string interpolation captures the value at execution time
    try db.exec("""
        INSERT INTO logs (message, timestamp)
        VALUES ('Counter is now \(state.counter)', datetime('now'))
    """)
}

// All database operations are part of the same transaction
// If any operation fails, the entire update is rolled back
```

### SQLAction - Command Pattern

For a cleaner separation of concerns, you can define actions that encapsulate state updates:

```swift
struct IncrementCounterAction: SQLAction {
    let amount: Int
    
    typealias State = AppState
    
    var type: UpdateType {
        .undoable
    }
    
    func update(state: inout AppState, db: SQLConnection) throws {
        state.counter += amount
        
        // Actions can also perform database operations
        let query: SQLStaticQuery = """
            INSERT INTO counter_history (value, change, timestamp)
            VALUES (\(state.counter), \(amount), datetime('now'))
        """
        try db.execute(query)
    }
}

struct ChangeThemeAction: SQLAction {
    let theme: String
    
    typealias State = AppState
    
    func update(state: inout AppState, db: SQLConnection) throws {
        state.preferences.theme = theme
    }
}

// Dispatch actions
let store = SQLCipherStore(db: db, state: initialState)

// Await completion
await store.dispatch(IncrementCounterAction(amount: 5))

// Fire-and-forget
store.dispatch(ChangeThemeAction(theme: "dark"))

// Actions automatically use their declared UpdateType
```

#### Action with Critical Update

```swift
struct ResetStoreAction: SQLAction {
    typealias State = AppState
    
    var type: UpdateType {
        .critical  // Cannot be undone
    }
    
    func update(state: inout AppState, db: SQLConnection) throws {
        state.counter = 0
        state.userName = "Guest"
        
        // Critical actions often involve database cleanup
        try db.exec("DELETE FROM counter_history")
    }
}

await store.dispatch(ResetStoreAction())
// State is reset, and this cannot be undone
```

### Integration with SwiftUI

`SQLCipherStore` is `@Observable`, making it perfect for SwiftUI integration:

```swift
import SwiftUI

@main
struct MyApp: App {
    let store: SQLCipherStore<AppState>
    
    init() {
        let db = try! SQLCipher(path: dbPath, key: encryptionKey)
        let initialState = AppState(counter: 0, userName: "Guest", preferences: UserPreferences(theme: "light", notifications: true))
        self.store = SQLCipherStore(db: db, state: initialState)
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}

struct ContentView: View {
    let store: SQLCipherStore<AppState>
    
    var body: some View {
        VStack {
            Text("Counter: \(store.counter)")
            
            Button("Increment") {
                store.update(.undoable) { state, db in
                    state.counter += 1
                }
            }
            
            Button("Undo") {
                store.undo()
            }
            .disabled(!store.canUndo)
            
            Button("Redo") {
                store.redo()
            }
            .disabled(!store.canRedo)
        }
    }
}
```

## Migration and Upgrades

When upgrading to new versions of this package, review the release notes for any breaking changes or migration requirements. Database files created with older versions remain compatible with newer versions, but you should maintain backups before performing upgrades in production environments.

For major version upgrades, consider implementing migration logic that handles state schema changes. The Redux pattern naturally supports this through versioned state structures and migration reducers that transform old state formats into new ones.

## Contributing

Contributions are welcome and appreciated. Before submitting pull requests, please review the existing code style and ensure your changes maintain API consistency. For significant features or architectural changes, consider opening an issue first to discuss the proposed approach.

When contributing, follow these guidelines:

- Write clear commit messages explaining the purpose of each change
- Include documentation for new APIs and modifications to existing ones
- Add tests for new functionality and ensure existing tests continue to pass
- Update the CHANGELOG.md file with a description of your changes under the appropriate version heading

## License

This package is licensed under the BSD-style license provided by ZETETIC LLC. SQLCipher itself is licensed under a similar BSD-style license that permits both free and commercial use with appropriate attribution.

Copyright (c) 2020, ZETETIC LLC - All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
- Neither the name of ZETETIC LLC nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## Acknowledgments

This package builds upon the excellent work of the SQLCipher team at ZETETIC LLC, who created and maintain the underlying encrypted SQLite implementation. Their commitment to open-source software has made secure local data storage accessible to developers across all platforms.

## Updating C Sources

This package includes C source files that may occasionally need updating to incorporate bug fixes, security patches, or new features from upstream projects.

### SQLCipher Sources (sqlite3.c, sqlite3.h)

The SQLCipher sources are downloaded from the official SQLCipher release. To update:

1. Download the latest SQLCipher release from [ZETETIC](https://www.zetetic.net/sqlcipher/)

2. Extract the archive and locate `sqlite3.c` and `sqlite3.h`

3. Copy them to `Sources/CSQLCipher/`:
   ```bash
   cp /path/to/sqlcipher/sqlite3.c Sources/CSQLCipher/
   cp /path/to/sqlcipher/sqlite3.h Sources/CSQLCipher/include/
   ```

4. Ensure the following compile flags remain defined in `Package.swift`:
   - `SQLITE_HAS_CODEC` - Enables encryption support
   - `SQLITE_TEMP_STORE=3` - Store temp tables in memory
   - `SQLITE_ENABLE_FTS5` - Full-text search support

### sqlite-vec Extension (sqlite-vec.c, sqlite-vec.h)

The vector search extension is maintained separately in the [asg017/sqlite-vec](https://github.com/asg017/sqlite-vec) repository. To update:

1. Visit the [sqlite-vec releases page](https://github.com/asg017/sqlite-vec/releases) to find the version you want

2. Download the `sqlite-vec.c` and `sqlite-vec.h.tmpl` (rename to `.h`) files

3. Copy them to the appropriate locations:
   ```bash
   cp /path/to/sqlite-vec.c Sources/CSQLCipher/
   cp /path/to/sqlite-vec.h.tmpl Sources/CSQLCipher/include/sqlite-vec.h
   ```

4. The `vec_init.c` file in `Sources/CSQLCipher/` registers the extension automatically via `sqlite3_auto_extension()`. If the initialization API changes, you may need to update this file.

5. Verify `SQLITE_VEC_STATIC` is defined in `Package.swift` to enable static linking.

## Support

For issues, questions, or feature requests, please open a GitHub issue on the repository. For questions about SQLCipher licensing for commercial applications, contact ZETETIC LLC directly.
