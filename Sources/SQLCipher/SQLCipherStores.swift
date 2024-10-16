//
//  SQLCipherStores.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 10/16/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import Foundation
import Combine

/// A protocol for containers that manage a versioned state structure within an SQLCipher database.
protocol SQLCipherStores: AnyObject {
    associatedtype State: Codable & Equatable
    
    /// The `SQLCipher` store where state updates will be saved.
    var cipher: SQLCipher { get }
    
    /// Published states
    var states: CurrentValueSubject<State, Never> { get }
    
    /// Published errors
    var errors: CurrentValueSubject<Error?, Never> { get }
    
    /// The name of the table in which this container's data is stored.
    var table: String { get }
    
    /// Initializes the container with a specified `SQLCipher` store and an initial state.
    init(store: SQLCipher, initial: State) throws
}

extension SQLCipherStores {
    var state: State {
        get { states.value }
    }
    
    var error: Error? {
        get { errors.value }
    }
    
    func update(_ work: (Database, inout State) throws -> Void) {
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
    
    var table: String {
        String(describing: State.self)
    }
    
    func initialize(initial: State) throws -> State {
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
    
    func saveState(_ state: State, using db: Database) throws {
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

enum VacuumStyle {
    case olderThan(Date)
    case copiesBeyond(Int)
}

extension SQLCipherStores {
    func vacuum(_ style: VacuumStyle) throws {
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

final class SQLCipherStore<State: Codable & Equatable>: SQLCipherStores {
    let cipher: SQLCipher
    let states: CurrentValueSubject<State, Never>
    let errors: CurrentValueSubject<Error?, Never>
        
    required init(store: SQLCipher, initial: State) throws {
        self.cipher = store
        self.errors = CurrentValueSubject(nil)
        self.states = CurrentValueSubject(initial)

        self.states.send(try initialize(initial: initial))
    }
}
