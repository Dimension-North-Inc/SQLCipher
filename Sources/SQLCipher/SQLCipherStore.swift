//
//  SQLCipherStores.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 10/16/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import Foundation
import Combine
import OSLog

public typealias SQLStoreState = Sendable & Codable & Equatable

@Observable
@dynamicMemberLookup
open class SQLCipherStore<State: SQLStoreState> {
    public let db: SQLCipher
    public let table: String

    /// The current state of the container.
    public private(set) var state: State
    /// The latest error encountered, if any.
    public private(set) var error: Error?

    private var undoCursor: Date? = nil
    
    /// Notifies concrete subclasses that state update has occurred.
    ///
    /// - Parameters:
    ///   - previous: previous state
    ///   - current: current state
    open func updated(previous: State, current: State) {}
    
    private func emit(_ current: State) {
        log.trace("emitting state")
        
        let previous = self.state
        self.state = current
        
        self.updated(previous: previous, current: current)
    }
    
    private func emit(_ error: Error?) {
        log.trace("emitting error \(error?.localizedDescription ?? "nil")")
        self.error = error
    }

    /// Initializes the `SQLCipherStore` with a specified `SQLCipher` store
    /// and an initial state.
    ///
    /// - Parameters:
    ///   - db: The `SQLCipher` database where the state is stored.
    ///   - initial: The initial state to use if the table is empty.
    /// - Throws: An error if the initialization fails.
    public init(db: SQLCipher, table: String? = nil, initial: State) {
        self.db      = db
        self.table   = table ?? String(describing: State.self)
        
        self.state   = initial
        self.error   = nil
                
        self.state   = initialize(initial: initial)
        
        self.updated(previous: initial, current: state)
    }
    
    /// Saves the provided state to the database.
    ///
    /// - Parameters:
    ///   - state: The state to save.
    ///   - db: The database connection to use for the operation.
    /// - Throws: An error if the save operation fails.
    private func saveState(_ state: State, using db: Database) throws {
        let insertSQL = """
        INSERT INTO \(table) (data)
        VALUES (:data)
        """
        
        let bindings: [String: SQLValue] = [
            "data": try .encoded(state)
        ]
        
        try db.execute(insertSQL, bindings)
    }
    
    /// Initializes the state storage, creating the table if it does not
    /// exist, or loading the most recent state if it does.
    ///
    /// - Parameter initial: The state to initialize if no data exists.
    /// - Returns: The current state after loading or initialization.
    /// - Throws: An error if table creation or state loading fails.
    func initialize(initial: State) -> State {
        return db.write { db in
            do {
                let createTableSQL = """
                CREATE TABLE IF NOT EXISTS \(table) (
                    rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                    data BLOB NOT NULL,
                    undoable INTEGER DEFAULT 0,
                    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
                );
                CREATE INDEX IF NOT EXISTS idx_\(table)_undoable ON \(table)(undoable);
                CREATE INDEX IF NOT EXISTS idx_\(table)_timestamp ON \(table)(timestamp);
                """
                try db.exec(createTableSQL)
                
                let countSQL = "SELECT COUNT(*) AS count FROM \(table);"
                let result = try db.execute(countSQL, [])
                let count = result.first?["count"]?.numberValue ?? 0
                
                if count == 0 {
                    try saveState(initial, using: db)
                    return initial
                } else {
                    let fetchSQL = """
                    SELECT data FROM \(table)
                    ORDER BY timestamp DESC
                    LIMIT 1;
                    """
                    
                    let rows = try db.execute(fetchSQL)
                    guard let existing = rows.first?["data"]?.encodedValue(as: State.self) else {
                        throw NSError(domain: "CipherStateContainers", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to retrieve state data."])
                    }
                    
                    return existing
                }
            }
            catch {
                emit(error)
                return initial
            }
        }
    }
    
    public subscript<Value>(dynamicMember keyPath: KeyPath<State, Value>) -> Value {
        state[keyPath: keyPath]
    }
}


// MARK: - Query (Read-only functions)
extension SQLCipherStore {
    
    /// Performs a read-only query on the database and the current state, returning a result.
    /// This does not modify the state or trigger any state changes.
    ///
    /// - Parameter work: A closure that reads from the database and state, returning a result.
    /// - Returns: The result of the closure or `nil` if an error occurs.
    public func query<Result>(_ work: (Database, State) throws -> Result) -> Result? {
        do {
            return try db.read { db in
                return try work(db, state)
            }
        } catch {
            emit(error)
            return nil
        }
    }

    /// Performs a read-only query on the database and the current state, returning a result.
    /// This does not modify the state or trigger any state changes.
    ///
    /// - Parameter work: A closure that reads from the database and state, returning a result.
    /// - Returns: The result of the closure or `nil` if an error occurs.
    public func query<Result>(_ work: (Database, State) throws -> Result) rethrows -> Result {
        do {
            return try db.read { db in
                return try work(db, state)
            }
        } catch {
            emit(error)
            throw error
        }
    }

    /// Asynchronously performs a read-only query on the database and the current state.
    /// This does not modify the state or trigger any state changes.
    ///
    /// - Parameter work: An asynchronous closure that reads from the database and state, returning a result.
    /// - Returns: The result of the closure or `nil` if an error occurs.
    public func query<Result>(_ work: (Database, State) async throws -> Result) async -> Result? {
        do {
            return try await db.read { db in
                return try await work(db, state)
            }
        } catch {
            emit(error)
            return nil
        }
    }
    
    /// Asynchronously performs a read-only query on the database and the current state.
    /// This does not modify the state or trigger any state changes.
    ///
    /// - Parameter work: An asynchronous closure that reads from the database and state, returning a result.
    /// - Returns: The result of the closure or `nil` if an error occurs.
    public func query<Result>(_ work: (Database, State) async throws -> Result) async rethrows -> Result {
        do {
            return try await db.read { db in
                return try await work(db, state)
            }
        } catch {
            emit(error)
            throw error
        }
    }

}


// MARK: - Update
extension SQLCipherStore {
    /// Deletes rows more recent than the undo cursor.
    ///
    /// - Parameter db: The database connection.
    /// - Throws: An error if the cleanup operation fails.
    /// - Returns: `true` if the cursor was reset and the next update must save.
    private func resetUndoCursor(using db: Database) throws -> Bool {
        guard let undoTimestamp = undoCursor else { return false }
        
        // Delete rows with timestamps between the undo cursor and the most recent row
        let cleanupSQL = """
        DELETE FROM \(table)
        WHERE timestamp > datetime(:cursor)
        );
        """
        try db.execute(cleanupSQL, ["cursor": .date(undoTimestamp)])
        
        undoCursor = nil
        
        return true
    }
    
    /// Updates the state within a database transaction. If an error occurs,
    /// the transaction is rolled back and the error is published.
    ///
    /// - Parameter save: True if the update should save state to the database, defaults to `true`
    /// - Parameter transform: An asynchronous closure that updates the database and modifies the state.
    public func update(save: Bool = true, transform: (Database, inout State) throws -> Void) {
        do {
            try db.write { db in
                try db.begin()
                
                var tempState = state
                try transform(db, &tempState)
                
                if tempState != state {
                    let shouldSave = try resetUndoCursor(using: db)
                    if save || shouldSave { try saveState(tempState, using: db) }
                }
                
                try db.commit()
                emit(tempState)
            }
        } catch {
            try? db.write { db in try db.rollback() }
            emit(error)
        }
    }

    /// Updates the state within a database transaction and returns a result.
    /// If an error occurs, the transaction is rolled back, the error is published,
    /// and the function returns `nil`.
    ///
    /// - Parameter save: True if the update should save state to the database, defaults to `true`
    /// - Parameter transform: An asynchronous closure that updates the database and modifies the state.
    /// - Returns: The result of the closure, or `nil` if an error occurs.
    public func updateReturning<Result>(save: Bool = true, transform: (Database, inout State) throws -> Result) -> Result? {
        do {
            return try db.write { db in
                try db.begin()
                
                var tempState = state
                let result = try transform(db, &tempState)
                
                if tempState != state {
                    let shouldSave = try resetUndoCursor(using: db)
                    if save || shouldSave { try saveState(tempState, using: db) }
                }

                try db.commit()
                emit(tempState)
                return result
            }
        } catch {
            try? db.write { db in try db.rollback() }
            emit(error)
            return nil
        }
    }

    /// Asynchronously updates the state within a database transaction. If an error occurs,
    /// the transaction is rolled back and the error is published.
    ///
    /// - Parameter save: True if the update should save state to the database, defaults to `true`
    /// - Parameter transform: An asynchronous closure that updates the database and modifies the state.
    public func update(save: Bool = true, transform: (Database, inout State) async throws -> Void) async {
        do {
            try await db.write { db in
                try db.begin()
                
                var tempState = state
                try await transform(db, &tempState)
                
                if tempState != state {
                    let shouldSave = try resetUndoCursor(using: db)
                    if save || shouldSave { try saveState(tempState, using: db) }
                }

                try db.commit()
                emit(tempState)
            }
        } catch {
            try? db.write { db in try db.rollback() }
            emit(error)
        }
    }

    /// Asynchronously updates the state within a database transaction and returns a result.
    /// If an error occurs, the transaction is rolled back, the error is published,
    /// and the function returns `nil`.
    ///
    /// - Parameter save: True if the update should save state to the database, defaults to `true`
    /// - Parameter transform: An asynchronous closure that updates the database and modifies the state.
    /// - Returns: The result of the closure, or `nil` if an error occurs.
    @_disfavoredOverload
    public func updateReturning<Result>(save: Bool = true, transform: (Database, inout State) async throws -> Result) async -> Result? {
        do {
            return try await db.write { db in
                try db.begin()
                
                var tempState = state
                let result = try await transform(db, &tempState)
                
                if tempState != state {
                    let shouldSave = try resetUndoCursor(using: db)
                    if save || shouldSave { try saveState(tempState, using: db) }
                }

                try db.commit()
                emit(tempState)
                return result
            }
        } catch {
            try? db.write { db in try db.rollback() }
            emit(error)
            return nil
        }
    }
}


// MARK: - Update Actions
extension SQLCipherStore {
    /// Dispatches a single action, updating the state within a database transaction.
    /// If the action conforms to `SQLStoreUndoable`, the most recent row will be marked as undoable
    /// *before* the action executes.
    ///
    /// - Parameter action: The action to execute.
    public func dispatch(_ action: some SQLStoreAction<State>) {
        log.trace("Dispatching Action: \(String(describing: action))")
        
        if action is SQLStoreUndoable {
            setUndoable()
        }
        
        update(save: action is SQLStoreUndoable) { db, state in
            try action.update(state: &state, db: db)
        }
    }
    
    /// Dispatches a composite action, executing its updates and returning its result.
    ///
    /// - Parameter action: The composite action to execute.
    /// - Returns: The result of the action.
    public func dispatch<Result>(_ action: some SQLStoreCompositeAction<State, Result>) -> Result {
        log.trace("Dispatching Composite Action: \(String(describing: action))")
        
        if action is SQLStoreUndoable {
            setUndoable()
        }
        
        return action.execute(in: self)
    }
}

    
// MARK: - Undo/Redo
extension SQLCipherStore {
    /// Marks or clears the current state as undoable.
    ///
    /// - Parameter isUndoable: A Boolean value indicating whether the current state should be marked as undoable. Defaults to `true`.
    public func setUndoable(_ isUndoable: Bool = true) {
        try? db.write { db in
            let markUndoSQL = """
            UPDATE \(table)
            SET undoable = ?
            WHERE rowid = (SELECT rowid FROM \(table) ORDER BY timestamp DESC LIMIT 1)
            """
            try db.execute(markUndoSQL, [.number(isUndoable ? 1 : 0)])
        }
    }

    /// Moves the undo cursor to the previous undoable row and updates the state.
    ///
    /// If a previous undoable row exists, it updates the state to that row and adjusts the undo cursor.
    /// If no such row exists, no action is performed.
    public func undo() {
        let undoTimestamp = undoCursor ?? Date()

        try? db.write { db in
            let findPreviousUndoSQL = """
            SELECT timestamp, data FROM \(table)
            WHERE undoable = 1 AND timestamp < datetime(:current)
            ORDER BY timestamp DESC LIMIT 1;
            """
            let result = try db.execute(findPreviousUndoSQL, ["current": .date(undoTimestamp)])

            guard let row = result.first,
                  let timestamp = row["timestamp"]?.dateValue,
                  let data = row["data"]?.encodedValue(as: State.self) else { return }

            undoCursor = timestamp
            emit(data)
        }
    }

    /// Moves the undo cursor to the next undoable row and updates the state.
    ///
    /// If a next undoable row exists, it updates the state to that row and adjusts the undo cursor.
    /// If no such row exists, the undo cursor is reset and the most recent state is emitted.
    public func redo() {
        guard let undoTimestamp = undoCursor else { return }

        try? db.write { db in
            let findNextUndoSQL = """
            SELECT timestamp, data FROM \(table)
            WHERE undoable = 1 AND timestamp > datetime(:current)
            ORDER BY timestamp ASC LIMIT 1;
            """
            let result = try db.execute(findNextUndoSQL, ["current": .date(undoTimestamp)])

            if let row = result.first,
               let timestamp = row["timestamp"]?.dateValue,
               let data = row["data"]?.encodedValue(as: State.self) {
                // Found a redoable row; update state and cursor
                undoCursor = timestamp
                emit(data)

            } else {
                // No more redoable rows; reset undoCursor and emit the most recent state
                let fetchMostRecentSQL = """
                SELECT data FROM \(table)
                ORDER BY timestamp DESC
                LIMIT 1;
                """
                let rows = try db.execute(fetchMostRecentSQL)
                guard let data = rows.first?["data"]?.encodedValue(as: State.self) else { return }

                undoCursor = nil
                emit(data)
            }
        }
    }
}


// MARK: - Maintenance
public enum VacuumStyle {
    case olderThan(Date)
    case copiesBeyond(Int)
}

extension SQLCipherStore {
    /// Vacuums the database table, deleting rows based on the provided style.
    ///
    /// - Parameter style: The criteria for selecting rows to delete.
    /// - Throws: An error if the vacuum operation fails.
    public func vacuum(_ style: VacuumStyle) throws {
        try db.write { db in
            var deleteSQL = "DELETE FROM \(table) WHERE rowid IN (SELECT rowid FROM \(table)"
            
            switch style {
            case .olderThan(let date):
                let timestamp = date.timeIntervalSince1970
                deleteSQL += " WHERE timestamp < datetime(\(timestamp), 'unixepoch'))"
                
            case .copiesBeyond(let maxCount):
                deleteSQL += " WHERE rowid NOT IN (SELECT rowid FROM \(table) ORDER BY timestamp DESC LIMIT \(maxCount)))"
            }
            
            try db.exec(deleteSQL)
        }
    }
}


// Package-internal logger for SQLCipher operations
private let log = Logger(subsystem: "com.dimension-north.SQLCipher", category: "SQLCipherStore")
