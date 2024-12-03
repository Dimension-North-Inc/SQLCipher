//
//  SQLStoreCompositeAction.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 12/3/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import Foundation

public protocol SQLStoreCompositeAction<State> {
    associatedtype State: Codable & Equatable
    
    /// Executes the composite action, allowing updates to be chunked into logical transactions.
    ///
    /// - Parameter store: The `SQLCipherStore` on which the action will operate.
    func execute(in store: SQLCipherStore<State>)
}
