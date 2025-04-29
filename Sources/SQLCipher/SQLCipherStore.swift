//
//  SQLCipherStore.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 2/1/25.
//  Copyright © 2025 Dimension North Inc. All rights reserved.
//

import Foundation

@Observable
@dynamicMemberLookup
open class SQLCipherStore<State> {
    /// Container storage
    public let db: SQLCipher
    
    /// The current state of the container.
    public var state: State {
        updates[current].state
    }
    
    /// The latest error encountered, if any.
    public private(set) var error: Error?
    
    struct Update {
        let state: State
        let type:  UpdateType
        
        static func undoable(_ state: State) -> Self {
            .init(state: state, type: .undoable)
        }
        static func pending(_ state: State) -> Self {
            .init(state: state, type: .pending)
        }
    }
    
    private var updates: [Update]
    private var current: Int
    
    private let substates: [Substate<State>]
    
    public var levelsOfUndo: Int = 50 {
        didSet {
            levelsOfUndo = max(0, levelsOfUndo)
        }
    }
    
    public init(db: SQLCipher, state: State, substates: [Substate<State>]) {
        Self.initializeStateStorage(db: db)
        
        self.db      = db
                
        let restored = Self.restoreSubstates(substates, state: state, db: db)
        
        self.updates = [.undoable(restored)]
        self.current = 0
        
        self.substates = substates
    }
    
    public convenience init(db: SQLCipher, state: State) where State: Stored {
        self.init(db: db, state: state, substates: [Substate(\.self)])
    }
    
    public func update(_ type: UpdateType, transform: (inout State, SQLConnection) throws -> Void) {
        do {
            let old = state
            var new = state
            
            let writer = db.writer
            
            try writer.begin()
            
            try transform(&new, writer)
            
            // undo management
            switch type {
            case .undoable, .critical:
                if updates[current].type == .pending {
                    // If we have an ephemeral state, commit it by replacing the previous undoable
                    // and then add our new undoable state
                    updates =
                    Array(updates[0..<(current)]) + [
                        .undoable(old),
                        .undoable(new),
                    ]
                    current += 1
                } else {
                    // Normal case - just add the new undoable state
                    updates = updates[0...current] + [.undoable(new)]
                    current += 1
                }
                
                // Trim excess undo levels if needed
                // maxUndoLevels + 1 to account for current state
                let maximumUpdateLength = levelsOfUndo + 1
                if updates.count > maximumUpdateLength {
                    let excessUpdates = updates.count - maximumUpdateLength
                    updates.removeFirst(excessUpdates)
                    current -= excessUpdates
                }
                
            case .pending:
                if updates[current].type == .pending {
                    // Replace existing ephemeral update
                    
                    // Note that updates marked .pending can only
                    // exist where `current == updates.count - 1`, ie.
                    // at the top of the update stack.
                    
                    updates[current] = .pending(new)
                } else {
                    // Push new ephemeral update
                    updates = updates[0...current] + [.pending(new)]
                    current += 1
                }
            }
            
            // substate management
            Self.saveSubstates(substates, states: (old: old, new: new), update: type, db: db)
            
            try writer.commit()
        }
        catch {
            self.error = error
        }
    }
    
    public subscript<T>(dynamicMember keyPath: KeyPath<State, T>) -> T {
        return state[keyPath: keyPath]
    }
}

extension SQLCipherStore {
    // MARK: - Undo/Redo
    public var canUndo: Bool {
        current > 0
    }

    public var canRedo: Bool {
        current < updates.count - 1
    }

    public func undo() {
        guard canUndo else { return }
        
        let old = updates[current].state
        let new = updates[current - 1].state
        
        Self.saveSubstates(substates, states: (old: old, new: new), update: .undoable, db: db)
        
        current -= 1
        
    }

    public func redo() {
        guard canRedo else { return }
        
        let old = updates[current].state
        let new = updates[current + 1].state
        
        Self.saveSubstates(substates, states: (old: old, new: new), update: .undoable, db: db)

        current += 1
    }
}

// State Persistence
extension SQLCipherStore {
    /// Restores perstistent `substates` into `state`
    /// - Parameters:
    ///   - substates: an array of persistent substates
    ///   - state: an initial state
    /// - Returns: a fully restored state
    private static func restoreSubstates(_ substates: [Substate<State>], state: State, db: SQLCipher) -> State {
        var restored = state

        for substate in substates {
            // FIXME: sample implementation
            guard let data = stateData(forKey: substate.key, db: db) else {
                continue
            }
            guard let value = try? substate.decode(from: data) else {
                continue
            }
            substate.write(to: &restored, value: value)

        }
        return restored
    }

    /// Saves  `substates` to persistent storage, based on update type
    /// - Parameters:
    ///   - substates: an array of persistent substates
    ///   - states: the current state
    ///   - update: a state update type
    private static func saveSubstates(
        _ substates: [Substate<State>], states: (old: State, new: State), update: UpdateType, db: SQLCipher
    ) {
        switch update {
        case .undoable:
            for substate in substates {
                let old = substate.read(from: states.old)
                let new = substate.read(from: states.new)

                if !new.isEqual(to: old) {
                    try? setStateData(substate.encode(from: states.new), forKey: substate.key, db: db)
                }
            }

        case .critical:
            for substate in substates {
                try? setStateData(substate.encode(from: states.new), forKey: substate.key, db: db)
            }

        case .pending:
            return
        }
    }
    
    
    private static func initializeStateStorage(db: SQLCipher) {
        do {
            try db.writer.exec("CREATE TABLE IF NOT EXISTS stored_substates (key TEXT PRIMARY KEY, value BLOB)")
        }
        catch {
            print("\(#function): \(error)")
        }
    }

    private static func stateData(forKey key: String, db: SQLCipher) -> Data? {
        do {
            let query: SQLStaticQuery = "SELECT value FROM stored_substates WHERE key = \(key)"
            return try db.reader.execute(query).first?.value
        }
        catch {
            print("\(#function): \(error)")
            return nil
        }
    }

    private static func setStateData(_ data: Data, forKey key: String, db: SQLCipher) {
        do {
            let query: SQLStaticQuery = "INSERT OR REPLACE INTO stored_substates (key, value) VALUES (\(key), \(data))"
            let _ = try db.writer.execute(query)
        }
        catch {
            print("\(#function): \(error)")
        }
    }
}
