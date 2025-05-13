//
//  SQLCipherStore.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 2/1/25.
//  Copyright © 2025 Dimension North Inc. All rights reserved.
//

import Foundation

/// A generic, observable, undoable state container backed by a SQLCipher database.
///
/// `SQLCipherStore` manages a value of type `State`, providing transactional updates,
/// undo/redo support, and persistent substate storage. Updates are performed via
/// closures that mutate the state and can interact with the underlying database.
///
/// - Note: All updates are transactional and can be undone/redone up to `levelsOfUndo` times.
/// - Warning: This class is main-actor isolated and safe for use from UI code. All database
///            and persistence work is performed off the main thread for UI responsiveness.
@MainActor
@Observable
@dynamicMemberLookup
open class SQLCipherStore<State: Sendable> {
    /// The underlying SQLCipher database.
    public let db: SQLCipher

    /// The current state of the container.
    ///
    /// This reflects the latest committed or pending state, depending on the update stack.
    public var state: State {
        updates[current].state
    }

    /// The latest error encountered during an update, if any.
    ///
    /// This is set when a non-throwing update fails.
    public private(set) var error: Error?

    struct Update: Sendable {
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

    /// The maximum number of undoable states to retain.
    ///
    /// Defaults to 50. Setting this to 0 disables undo.
    public var levelsOfUndo: Int = 50 {
        didSet {
            levelsOfUndo = max(0, levelsOfUndo)
        }
    }

    /// Serial queue for all update operations, ensuring transactional integrity and thread safety.
    private let updateQueue = DispatchQueue(label: "com.dimension-north.SQLCipher.Store.update")

    /// Initializes a new store with the given database, initial state, and substates.
    ///
    /// - Parameters:
    ///   - db: The SQLCipher database to use for persistence.
    ///   - state: The initial state value.
    ///   - substates: An array of substates to persist independently.
    public init(db: SQLCipher, state: State, substates: [Substate<State>]) {
        Self.initializeStateStorage(db: db)
        
        self.db         = db
        
        let restored    = Self.restoreSubstates(substates, state: state, db: db)
        
        self.updates    = [.undoable(restored)]
        self.current    = 0
        
        self.substates  = substates
    }

    /// Initializes a new store with a single persistent state.
    ///
    /// - Parameters:
    ///   - db: The SQLCipher database to use for persistence.
    ///   - state: The initial state value, which must conform to `Stored`.
    public convenience init(db: SQLCipher, state: State) where State: Stored {
        self.init(db: db, state: state, substates: [Substate(\.self)])
    }

    /// Provides dynamic member lookup for the current state.
    ///
    /// - Parameter keyPath: A key path into the state.
    /// - Returns: The value at the given key path in the current state.
    public subscript<T>(dynamicMember keyPath: KeyPath<State, T>) -> T {
        return state[keyPath: keyPath]
    }
}

// MARK: - Update API

extension SQLCipherStore {
    
    private func lastUndoableStateIndex() -> Int {
        for i in stride(from: current, through: 0, by: -1) {
            if updates[i].type == .undoable {
                return i
            }
        }
        return 0 // fallback, should never happen
    }

    @discardableResult
    internal func _update<T: Sendable>(
        _ type: UpdateType,
        transform: @Sendable @escaping (inout State, SQLConnection) throws -> T
    ) async throws -> T {
        let old = state
        let writer = db.writer

        // Capture main-actor properties for use in the background queue
        let db = self.db
        let substates = self.substates
        
        let updatesCopy = self.updates
        let currentCopy = self.current

        let levelsOfUndoCopy = self.levelsOfUndo
        
        // All DB work, including substates, is performed off the main actor
        let result: Result<(T, State, [Update], Int), Error> = await withCheckedContinuation { continuation in
            updateQueue.async {
                var new = old
                var updates = updatesCopy
                var current = currentCopy
                do {
                    // 1. Begin transaction
                    try writer.begin()
                    // 2. Call the transform closure
                    let value = try transform(&new, writer)

                    // 3. Substate management (inside transaction)
                    switch type {
                    case .undoable:
                        if updates[current].type == .pending {
                            // Find last undoable state in the stack
                            let lastUndoableIdx = (0...current).reversed().first(where: { updates[$0].type == .undoable }) ?? 0
                            let lastUndoable = updates[lastUndoableIdx].state
                            Self.saveSubstates(substates, states: (old: lastUndoable, new: new), update: .undoable, db: db)
                            // Update the stack: collapse pending into undoable
                            updates = Array(updates[0..<(current)]) + [
                                .undoable(old),
                                .undoable(new),
                            ]
                            current += 1
                        } else {
                            Self.saveSubstates(substates, states: (old: old, new: new), update: .undoable, db: db)
                            updates = updates[0...current] + [.undoable(new)]
                            current += 1
                        }
                        // Prune stack if needed
                        let maximumUpdateLength = levelsOfUndoCopy + 1
                        if updates.count > maximumUpdateLength {
                            let excessUpdates = updates.count - maximumUpdateLength
                            updates.removeFirst(excessUpdates)
                            current -= excessUpdates
                        }
                    case .critical:
                        Self.saveSubstates(substates, states: (old: old, new: new), update: .critical, db: db)
                        updates = updates[0...current] + [.undoable(new)]
                        current += 1
                        let maximumUpdateLength = levelsOfUndoCopy + 1
                        if updates.count > maximumUpdateLength {
                            let excessUpdates = updates.count - maximumUpdateLength
                            updates.removeFirst(excessUpdates)
                            current -= excessUpdates
                        }
                    case .pending:
                        if updates[current].type == .pending {
                            updates[current] = .pending(new)
                        } else {
                            updates = updates[0...current] + [.pending(new)]
                            current += 1
                        }
                    }

                    // 4. Commit transaction
                    try writer.commit()
                    // Pass both the result, the new state, and the updated stack back
                    continuation.resume(returning: .success((value, new, updates, current)))
                } catch {
                    // On error: rollback
                    try? writer.rollback()
                    continuation.resume(returning: .failure(error))
                }
            }
        }

        // Undo management and in-memory state update (on main actor)
        switch result {
        case .success(let (value, _, updates, current)):
            self.updates = updates
            self.current = current
            self.error = nil
            return value

        case .failure(let error):
            self.error = error
            throw error
        }
    }
    
    /// Performs an asynchronous, transactional, undoable update on the store's state.
    ///
    /// - Parameters:
    ///   - type: The type of update (`undoable`, `pending`, or `critical`).
    ///   - transform: A closure that mutates the state and can interact with the database.
    ///                The closure may throw; if it does, the transaction is rolled back and the error is ignored.
    /// - Returns: The value returned by `transform`, or `nil` if an error occurred.
    ///
    /// - Note: Use this for updates where you do not need to handle errors explicitly.
    public func update<T: Sendable>(
        _ type: UpdateType,
        transform: @Sendable @escaping (inout State, SQLConnection) throws -> T
    ) async -> T? {
        try? await _update(type, transform: transform)
    }

    /// Performs an asynchronous, transactional, undoable update on the store's state, propagating errors.
    ///
    /// - Parameters:
    ///   - type: The type of update (`undoable`, `pending`, or `critical`).
    ///   - transform: A closure that mutates the state and can interact with the database.
    ///                The closure may throw; if it does, the transaction is rolled back and the error is rethrown.
    /// - Returns: The value returned by `transform`.
    /// - Throws: Any error thrown by `transform` or by the database.
    ///
    /// - Note: Use this for updates where you need to handle errors or await the result.
    public func tryUpdate<T: Sendable>(
        _ type: UpdateType,
        transform: @Sendable @escaping (inout State, SQLConnection) throws -> T
    ) async throws -> T {
        try await _update(type, transform: transform)
    }

    /// Performs a fire-and-forget, asynchronous update on the store's state.
    ///
    /// - Parameters:
    ///   - type: The type of update (`undoable`, `pending`, or `critical`).
    ///   - transform: A closure that mutates the state and can interact with the database.
    ///
    /// - Note: This method does not return a result or throw errors. Use for UI actions where you do not need to await completion or handle errors.
    public func update(
        _ type: UpdateType,
        transform: @Sendable @escaping (inout State, SQLConnection) throws -> Void
    ) {
        Task { [weak self] in
            _ = try? await self?._update(type, transform: transform)
        }
    }
}

// MARK: - Undo/Redo

extension SQLCipherStore {
    /// Indicates whether an undo operation is possible.
    public var canUndo: Bool {
        current > 0
    }

    /// Indicates whether a redo operation is possible.
    public var canRedo: Bool {
        current < updates.count - 1
    }

    /// Undoes the last update, if possible.
    ///
    /// - Note: If no undo is available, this method does nothing.
    public func undo() {
        guard canUndo else { return }
        let old = updates[current].state
        let new = updates[current - 1].state
        Self.saveSubstates(substates, states: (old: old, new: new), update: .undoable, db: db)
        current -= 1
    }

    /// Redoes the last undone update, if possible.
    ///
    /// - Note: If no redo is available, this method does nothing.
    public func redo() {
        guard canRedo else { return }
        let old = updates[current].state
        let new = updates[current + 1].state
        Self.saveSubstates(substates, states: (old: old, new: new), update: .undoable, db: db)
        current += 1
    }
}

// MARK: - State Persistence

// These static methods are not main-actor isolated and are safe to call from background queues.
extension SQLCipherStore {
    /// Restores persistent `substates` into `state`.
    ///
    /// - Parameters:
    ///   - substates: An array of persistent substates.
    ///   - state: An initial state.
    ///   - db: The SQLCipher database to use for loading substates.
    /// - Returns: A fully restored state.
    nonisolated static func restoreSubstates(
        _ substates: [Substate<State>],
        state: State,
        db: SQLCipher
    ) -> State {
        var restored = state
        for substate in substates {
            guard let data = stateData(forKey: substate.key, db: db) else { continue }
            guard let value = try? substate.decode(from: data) else { continue }
            substate.write(to: &restored, value: value)
        }
        return restored
    }

    /// Persists substates to the database as part of a transactional update.
    ///
    /// - Parameters:
    ///   - substates: The substates to persist.
    ///   - states: A tuple containing the old and new state values.
    ///   - update: The type of update being performed.
    ///   - db: The SQLCipher database to use.
    ///
    /// - Note: This function is not main-actor isolated and is safe to call from a background queue.
    nonisolated static func saveSubstates(
        _ substates: [Substate<State>],
        states: (old: State, new: State),
        update: UpdateType,
        db: SQLCipher
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

    /// Initializes persistent storage for substates, creating the table if needed.
    ///
    /// - Parameter db: The SQLCipher database to use.
    nonisolated static func initializeStateStorage(db: SQLCipher) {
        do {
            try db.writer.exec("CREATE TABLE IF NOT EXISTS stored_substates (key TEXT PRIMARY KEY, value BLOB)")
        }
        catch {
            print("\(#function): \(error)")
        }
    }

    /// Loads state data for a given key from the database.
    ///
    /// - Parameters:
    ///   - key: The substate key.
    ///   - db: The SQLCipher database to use.
    /// - Returns: The data for the given key, or `nil` if not found or on error.
    nonisolated static func stateData(forKey key: String, db: SQLCipher) -> Data? {
        do {
            let query: SQLStaticQuery = "SELECT value FROM stored_substates WHERE key = \(key)"
            return try db.reader.execute(query).first?.value
        }
        catch {
            print("\(#function): \(error)")
            return nil
        }
    }

    /// Saves state data for a given key to the database.
    ///
    /// - Parameters:
    ///   - data: The data to save.
    ///   - key: The substate key.
    ///   - db: The SQLCipher database to use.
    nonisolated static func setStateData(_ data: Data, forKey key: String, db: SQLCipher) {
        do {
            let query: SQLStaticQuery = "INSERT OR REPLACE INTO stored_substates (key, value) VALUES (\(key), \(data))"
            let _ = try db.writer.execute(query)
        }
        catch {
            print("\(#function): \(error)")
        }
    }
}
