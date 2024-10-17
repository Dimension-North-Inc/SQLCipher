//
//  SQLCipherStores.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 10/16/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import Foundation
import Combine

/// A protocol for containers that manage a versioned state structure within an
/// SQLCipher database.
protocol SQLCipherStores: AnyObject {
    associatedtype State: Codable & Equatable
    
    /// The `SQLCipher` store where state updates will be saved.
    var cipher: SQLCipher { get }
    
    /// Publishes the current state of the container.
    var states: CurrentValueSubject<State, Never> { get }
    
    /// Publishes errors encountered during database operations.
    var errors: CurrentValueSubject<Error?, Never> { get }
    
    /// The name of the table in which this container's data is stored.
    var table: String { get }
    
    /// Initializes the container with a specified `SQLCipher` store and an
    /// initial state.
    ///
    /// - Parameters:
    ///   - store: The `SQLCipher` database where the state is stored.
    ///   - initial: The initial state to use if the table is empty.
    /// - Throws: An error if initialization fails.
    init(store: SQLCipher, initial: State) throws
}

extension SQLCipherStores {
    /// The current state of the container.
    public var state: State {
        get { states.value }
    }
    
    /// The latest error encountered, if any.
    public var error: Error? {
        get { errors.value }
    }
    
    /// Updates the state within a database transaction. If an error occurs,
    /// the transaction is rolled back and the error is published.
    ///
    /// - Parameter work: A closure that performs updates on the database and
    ///   modifies the state.
    public func update(_ work: (Database, inout State) throws -> Void) {
        do {
            try cipher.write { db in
                try db.begin()
                
                var tempState = state
                try work(db, &tempState)
                
                if tempState != state {
                    try saveState(tempState, using: db)
                }
                
                try db.commit()
                states.send(tempState)
            }
        } catch {
            try? cipher.write { db in try db.rollback() }
            errors.send(error)
        }
    }
    
    /// The name of the table used for storing the container's data,
    /// defaulting to the type name of `State`.
    public var table: String {
        String(describing: State.self)
    }
    
    /// Initializes the state storage, creating the table if it does not
    /// exist, or loading the most recent state if it does.
    ///
    /// - Parameter initial: The state to initialize if no data exists.
    /// - Returns: The current state after loading or initialization.
    /// - Throws: An error if table creation or state loading fails.
    public func initialize(initial: State) throws -> State {
        return try cipher.write { db in
            let createTableSQL = """
            CREATE TABLE IF NOT EXISTS \(table) (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                data BLOB NOT NULL,
                timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
            );
            CREATE INDEX IF NOT EXISTS idx_\(table)_timestamp ON \(table)(timestamp);
            """
            
            try db.exec(createTableSQL)
            
            let countSQL = "SELECT COUNT(*) AS count FROM \(table);"
            let result = try db.execute(countSQL, with: [])
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
    }
    
    /// Saves the provided state to the database.
    ///
    /// - Parameters:
    ///   - state: The state to save.
    ///   - db: The database connection to use for the operation.
    /// - Throws: An error if the save operation fails.
    public func saveState(_ state: State, using db: Database) throws {
        let insertSQL = """
        INSERT INTO \(table) (data)
        VALUES (:data)
        """
        
        let bindings: [String: Value] = [
            "data": try .encoded(state)
        ]
        
        try db.execute(insertSQL, with: bindings)
    }
}

public enum VacuumStyle {
    case olderThan(Date)
    case copiesBeyond(Int)
}

extension SQLCipherStores {
    /// Vacuums the database table, deleting rows based on the provided style.
    ///
    /// - Parameter style: The criteria for selecting rows to delete.
    /// - Throws: An error if the vacuum operation fails.
    public func vacuum(_ style: VacuumStyle) throws {
        try cipher.write { db in
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

public final class SQLCipherStore<State: Codable & Equatable>: SQLCipherStores {
    public let cipher: SQLCipher
    public let states: CurrentValueSubject<State, Never>
    public let errors: CurrentValueSubject<Error?, Never>
        
    /// Initializes the `SQLCipherStore` with a specified `SQLCipher` store
    /// and an initial state.
    ///
    /// - Parameters:
    ///   - store: The `SQLCipher` database where the state is stored.
    ///   - initial: The initial state to use if the table is empty.
    /// - Throws: An error if the initialization fails.
    public required init(store: SQLCipher, initial: State) throws {
        self.cipher = store
        self.errors = CurrentValueSubject(nil)
        self.states = CurrentValueSubject(initial)

        self.states.send(try initialize(initial: initial))
    }
}
