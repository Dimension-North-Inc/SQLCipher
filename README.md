# SQLCipher

A comprehensive Swift wrapper for SQLCipher that provides encrypted SQLite database functionality with two distinct usage patterns: standard database operations and a Redux-style state container powered by database-backed storage.

## Overview

This package delivers a robust Swift interface to SQLCipher, enabling developers to integrate encrypted SQLite databases into their iOS, macOS, watchOS, and tvOS applications. Beyond providing complete access to the SQLCipher C API through type-safe Swift interfaces, this package introduces an innovative Redux-style state management pattern where your application state is persisted directly to an encrypted database.

The package is designed with flexibility in mind, allowing developers to leverage either or both of its operating modes within a single application. Whether you need traditional database operations for complex queries and data relationships, or you prefer the predictability of Redux-style state management with automatic persistence, this package provides clean, well-documented APIs for both approaches.

## Features

### Standard Database Operations

The package provides full access to SQLCipher's encryption capabilities through a Swifty, type-safe API that abstracts away the complexities of the underlying C interface. You can perform all standard database operations including creating and opening databases with custom encryption keys, executing raw SQL statements, compiling prepared statements for repeated execution, and managing both read and write connections. The API follows Swift conventions and patterns, making it feel natural to developers familiar with Apple's frameworks while maintaining the power and flexibility of SQL.

Connection management is handled gracefully, with support for multiple concurrent connections and automatic resource cleanup. The package provides both synchronous and asynchronous APIs for operations that might block the calling thread, enabling you to integrate encrypted database access into applications with varying concurrency requirements. Transaction support allows you to group related operations into atomic units, ensuring data consistency even when operations fail midway through a sequence.

### Redux-Style State Container

The Redux-style state container represents a unique approach to application state management, combining the predictability of unidirectional data flow with the security of encrypted database persistence. In this architecture, your entire application state resides in a single, immutable store that can only be modified by dispatching actions. These actions describe what should change, and a reducer function translates the current state and an action into a new state.

What distinguishes this implementation is that the entire state tree is automatically persisted to the encrypted SQLCipher database, providing durability across application launches without requiring separate serialization logic. The state is stored efficiently using a normalized structure, with entities referenced by identifier rather than embedded directly. This approach mirrors the patterns used in popular JavaScript state management libraries while bringing them into the Swift ecosystem with full encryption support.

The state container integrates seamlessly with SwiftUI through property wrappers and observable objects, enabling reactive UI updates when state changes. You can observe state changes using Combine publishers, making it straightforward to integrate with existing reactive codebases. Middleware support allows you to extend the dispatch pipeline with logging, analytics, persistence side effects, or any other cross-cutting concerns.

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

## Quick Start

### Standard Database Usage

Begin by importing the module and opening a database connection. You provide an encryption key that will be used to encrypt the database file, and this same key must be supplied when opening the database in subsequent sessions.

```swift
import SQLCipher

// Open or create an encrypted database
let database = try Database(
    path: "path/to/your/database.sqlite",
    key: "your-secret-password"
)

// Execute a query to create a table
try database.execute("""
    CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        email TEXT UNIQUE NOT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
""")

// Insert data using parameterized queries
try database.execute(
    "INSERT INTO users (name, email) VALUES (?, ?)",
    parameters: ["Alice", "alice@example.com"]
)

// Query data with result handling
let users: [User] = try database.query("SELECT * FROM users")
for user in users {
    print("User: \(user.name), Email: \(user.email)")
}

// Use prepared statements for repeated queries
let statement = try database.prepare(
    "SELECT * FROM users WHERE email = ?"
)
try statement.execute(parameters: ["alice@example.com"])
```

### Redux State Container Usage

The Redux-style state container provides a declarative approach to state management. Define your state structure, create actions that describe state changes, write reducers that compute new states, and dispatch actions to modify the store. The store automatically persists your state to the encrypted database.

```swift
import SQLCipher

// Define your application state
struct AppState: State {
    var counter: Int = 0
    var todos: [Todo] = []
    var isLoading: Bool = false
}

// Define actions that can modify state
enum CounterAction: Action {
    case increment
    case decrement
    case set value(Int)
}

struct Todo: Codable, Identifiable {
    let id: UUID
    var title: String
    var isCompleted: Bool
}

// Define actions for todo management
enum TodoAction: Action {
    case add(String)
    case toggle(UUID)
    case remove(UUID)
}

// Write reducers that transform state based on actions
let appReducer: Reducer<AppState> = { state, action in
    var newState = state
    
    switch action {
    case let action as CounterAction:
        switch action {
        case .increment:
            newState.counter += 1
        case .decrement:
            newState.counter -= 1
        case let .set(value):
            newState.counter = value
        }
        
    case let action as TodoAction:
        switch action {
        case let .add(title):
            let todo = Todo(
                id: UUID(),
                title: title,
                isCompleted: false
            )
            newState.todos.append(todo)
            
        case let .toggle(id):
            if let index = newState.todos.firstIndex(where: { $0.id == id }) {
                newState.todos[index].isCompleted.toggle()
            }
            
        case let .remove(id):
            newState.todos.removeAll { $0.id == id }
        }
        
    default:
        break
    }
    
    return newState
}

// Create the store with your reducer and encryption
let store = try Store(
    initialState: AppState(),
    reducer: appReducer,
    databasePath: "path/to/state.sqlite",
    key: "state-encryption-key"
)

// Dispatch actions to modify state
store.dispatch(CounterAction.increment)
store.dispatch(CounterAction.increment)
store.dispatch(CounterAction.set(value: 10))

store.dispatch(TodoAction.add("Learn Swift"))
store.dispatch(TodoAction.add("Build apps"))

// Observe state changes
store.$state
    .receive(on: DispatchQueue.main)
    .sink { state in
        print("Counter: \(state.counter)")
        print("Todos: \(state.todos.count)")
    }
    .store(in: &cancellables)
```

## Advanced Usage

### Prepared Statements and Transactions

For operations that require multiple related queries or repeated execution, prepared statements and transactions provide performance benefits and data integrity guarantees. Prepared statements are compiled once and can be executed multiple times with different parameters, avoiding the overhead of parsing and planning for each execution.

```swift
// Create a prepared statement for repeated use
let insertStatement = try database.prepare(
    "INSERT INTO products (sku, name, price) VALUES (?, ?, ?)"
)

// Execute the same statement with different values
for product in products {
    try insertStatement.execute(parameters: [
        product.sku,
        product.name,
        product.price
    ])
}

// Use transactions for atomic operations
try database.transaction {
    try database.execute("UPDATE accounts SET balance = balance - ? WHERE id = ?", 
        parameters: [100, fromAccountId])
    try database.execute("UPDATE accounts SET balance = balance + ? WHERE id = ?",
        parameters: [100, toAccountId])
    try database.execute("INSERT INTO transactions (from, to, amount) VALUES (?, ?, ?)",
        parameters: [fromAccountId, toAccountId, 100])
}
```

### Middleware for State Container

Middleware allows you to extend the Redux dispatch pipeline with custom behavior. Common uses include logging, analytics, persistence, and side effects. Middleware receives each action before it reaches the reducer and can perform additional processing or even dispatch new actions.

```swift
// Logger middleware for debugging
let loggerMiddleware: Middleware<AppState> = { store, action, next in
    print("Dispatching action: \(action)")
    let before = store.state.value
    next(action)
    let after = store.state.value
    print("State changed: \(before) -> \(after)")
}

// Analytics middleware
let analyticsMiddleware: Middleware<AppState> = { store, action, next in
    next(action)
    
    if let analyticsAction = action as? AnalyticsTrackable {
        AnalyticsService.shared.track(
            event: analyticsAction.analyticsEvent,
            properties: analyticsAction.properties
        )
    }
}

// Apply middleware when creating the store
let store = try Store(
    initialState: AppState(),
    reducer: appReducer,
    databasePath: "path/to/state.sqlite",
    key: "state-encryption-key",
    middleware: [loggerMiddleware, analyticsMiddleware]
)
```

### Combining Database and State Container

Many applications benefit from using both the standard database interface and the state container together. You might use the state container for user interface state and application preferences while maintaining traditional database tables for complex data relationships or historical records. Both can share the same database file and encryption key, or they can use separate files for different security requirements.

```swift
// Use a single encrypted database for both purposes
let database = try Database(
    path: "shared-database.sqlite",
    key: "shared-encryption-key"
)

// Store application preferences in state container
let preferencesStore = try Store(
    initialState: AppPreferences(),
    reducer: preferencesReducer,
    databasePath: "shared-database.sqlite",
    key: "shared-encryption-key"
)

// Store complex relational data using standard database
try database.execute("""
    CREATE TABLE orders (
        id INTEGER PRIMARY KEY,
        user_id INTEGER,
        product_id INTEGER,
        quantity INTEGER,
        status TEXT,
        FOREIGN KEY (user_id) REFERENCES users(id)
    )
""")
```

## API Reference

### Database Class

The `Database` class provides the primary interface for standard SQLCipher operations.

**Initialization**

```swift
init(path: String, key: String, readonly: Bool = false) throws
```

Opens or creates a database at the specified path with the given encryption key. Set `readonly` to true for read-only access to existing databases.

**Executing Queries**

```swift
func execute(_ sql: String, parameters: [DatabaseValue] = []) throws
```

Executes a SQL statement that does not return results, such as CREATE TABLE, INSERT, UPDATE, or DELETE statements. Parameters can be bound to prevent SQL injection attacks.

**Querying Data**

```swift
func query<T: Decodable>(_ sql: String, parameters: [DatabaseValue] = []) throws -> [T]
```

Executes a SELECT query and automatically decodes the results into an array of Swift objects conforming to Decodable. This eliminates manual result parsing for common use cases.

**Prepared Statements**

```swift
func prepare(_ sql: String) throws -> Statement
```

Creates a prepared statement for repeated execution with potentially different parameters.

### Store Class

The `Store` class implements the Redux-style state container.

**Initialization**

```swift
init(
    initialState: S,
    reducer: @escaping Reducer<S>,
    databasePath: String,
    key: String,
    middleware: [Middleware<S>] = []
) throws
```

Creates a new store with the given initial state, reducer function, database path for persistence, encryption key, and optional middleware chain.

**Dispatching Actions**

```swift
func dispatch(_ action: Action)
```

Dispatches an action to the store, triggering the reducer to compute a new state and persisting the updated state to the database.

**State Observation**

```swift
var state: CurrentValueSubject<S, Never>
```

A Combine publisher that emits the current state whenever it changes. Use this with SwiftUI's `@ObservedObject` or with Combine's sink operator for reactive updates.

### Statement Class

The `Statement` class represents a compiled SQL statement.

**Execution**

```swift
func execute(parameters: [DatabaseValue]) throws
func execute() throws // For statements with no parameters
```

Executes the prepared statement with the provided parameter values.

**Iteration**

```swift
func iterate() throws -> AnyIterator<[String: DatabaseValue]>
```

Returns an iterator over the result rows, where each row is a dictionary mapping column names to their values.

## Security Considerations

The encryption provided by SQLCipher uses 256-bit AES in CBC mode by default, with a SHA-1 based HMAC for integrity verification. The encryption key you provide is never stored in the database; only the derived key material is retained. If you lose the key, your data is irrecoverably encrypted and cannot be accessed without it.

For production applications, consider how you will securely obtain and store the encryption key. Options include deriving the key from a user passphrase, retrieving it from a secure keychain, or using a hybrid approach where a keychain-stored master key encrypts per-database keys. Never hardcode keys in your application bundle, and consider using iOS/macOS Keychain services for key storage.

The state container stores your entire application state in the encrypted database. Be mindful of what information you include in state objects, as it will all be encrypted and persisted to disk. Sensitive data that should only be held in memory should not be included in the persisted state.

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

## Support

For issues, questions, or feature requests, please open a GitHub issue on the repository. For questions about SQLCipher licensing for commercial applications, contact ZETETIC LLC directly.
