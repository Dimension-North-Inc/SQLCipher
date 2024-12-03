//
//  SQLStoreAction.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 12/3/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import Foundation

public protocol SQLStoreAction<State> {
    associatedtype State: Codable & Equatable
    
    /// Performs the action, updating the state and optionally interacting with the database.
    ///
    /// - Parameters:
    ///   - state: The state of the store to modify.
    ///   - db: An auxiliary database connection for non-state-related operations.
    /// - Throws: Any errors encountered during the update process.
    func update(state: inout State, db: Database) throws
}

