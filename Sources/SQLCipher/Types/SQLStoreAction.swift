//
//  SQLStoreAction.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 12/3/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import Foundation

/// A protocol that defines a single state-modifying action within a `SQLCipherStore`.
///
/// Conforming types implement logic to modify the store's state or interact with the database
/// for auxiliary operations. Actions are executed within a single database transaction.
///
/// - Note: Use `SQLStoreAction` to define focused, self-contained updates to the state.
public protocol SQLStoreAction<State> {
    /// The type of the state managed by the store, conforming to `SQLStoreState`.
    associatedtype State: SQLStoreState

    /// Performs the action, updating the state and optionally interacting with the database.
    ///
    /// Implement this method to modify the state and perform any necessary database operations
    /// atomically within the store's transaction.
    ///
    /// - Parameters:
    ///   - state: An inout parameter representing the current state of the store. Modify this to reflect changes.
    ///   - db: A `Database` instance for auxiliary operations not directly related to the main state.
    /// - Throws: An error if the action fails or if any database operations cannot be completed.
    func update(state: inout State, db: Database) throws
}


/// A protocol that defines a composite action within a `SQLCipherStore`.
///
/// Conforming types implement logic that may involve multiple state updates or transactions.
/// Composite actions provide a way to orchestrate complex workflows that involve multiple atomic
/// updates, returning a final result.
///
/// - Note: Use `SQLStoreCompositeAction` for scenarios where a single action requires multiple
/// logical transactions or complex orchestration.
public protocol SQLStoreCompositeAction<State, Result> {
    /// The type of the state managed by the store, conforming to `SQLStoreState`.
    associatedtype State: SQLStoreState
    associatedtype Result

    /// Executes the composite action, allowing updates to be chunked into logical transactions.
    ///
    /// Implement this method to execute a series of updates within the store. You can call
    /// the store's `update` or `dispatch` methods as needed to manage state and transactions.
    ///
    /// - Parameter store: The `SQLCipherStore` instance on which the action operates.
    /// - Returns: The final result of the composite action.
    func execute(in store: SQLCipherStore<State>) -> Result
}
