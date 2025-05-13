//
//  SQLAction.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 12/3/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import Foundation

/// A protocol defining a single, state-modifying action within an `SQLCipherStore`.
///
/// Conforming types represent discrete updates to the store's state, optionally interacting with its underlying database.
/// Actions can be pending, undoable, or critical, as specified by their `type`.

public protocol SQLAction<State>: Sendable {
    /// The state type this action operates on, conforming to `Stored`.
    associatedtype State: Stored

    /// Performs the action, modifying the provided state and optionally interacting with the database.
    /// - Parameters:
    ///   - state: The current state, passed as an `inout` parameter for modification.
    ///   - db: An `SQLConnection` for database operations, such as querying or writing.
    /// - Throws: An error if the update fails (e.g., due to database issues).
    func update(state: inout State, db: SQLConnection) throws
    
    /// Specifies the update's persistence and undo behavior.
    /// Defaults to `.pending` if not overridden.
    var type: UpdateType { get }
}

extension SQLAction {
    public var type: UpdateType {
        return .pending
    }
}

/// Defines the persistence and undo behavior of an `SQLAction`.
public enum UpdateType: Sendable {
    /// An unpdate persisted with the next undoable or critical update.
    case pending
    /// An immediately persisted update which can be undone to some earlier state..
    case undoable
    /// An immediately persisted update which forms a new state baseline that can not be undone..
    case critical
}

extension SQLCipherStore {
    /**
     Dispatches an `SQLAction` to the store, performing its update as an async, transactional operation.

     - Parameter action: The action to perform.

     - Important: When this function returns, the action’s update has been fully applied:
        - The state mutation and any database work are complete.
        - The store’s `state` property reflects the new value.
        - All observers and SwiftUI views will see the updated state.
     - Note: Use this variant when you need to guarantee that the state is updated before proceeding.
     */
    public func dispatch(_ action: any SQLAction<State>) async {
        await update(action.type) { state, db in
            try action.update(state: &state, db: db)
        }
    }

    /**
     Dispatches an `SQLAction` to the store in a fire-and-forget manner.

     - Parameter action: The action to perform.

     - Important: This launches the action asynchronously and returns immediately.
        - The state change will occur at some point in the future.
        - There is no guarantee that the state has been updated when this function returns.
        - Use this for UI triggers or when you do not need to await completion or handle errors.
     */
    public func dispatch(_ action: any SQLAction<State>) {
        Task { [weak self] in
            await self?.update(action.type) { state, db in
                try action.update(state: &state, db: db)
            }
        }
    }
}
