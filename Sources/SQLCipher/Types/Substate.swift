//
//  Substate.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 2/3/25.
//  Copyright © 2025 Dimension North Inc. All rights reserved.
//

import Foundation

/// The persistent `Substate` of a larger `State`, stored in a SQLCipher database
public struct Substate<State> {
    let key: String

    private let read: (State) -> any Stored
    private let write: (inout State, any Stored) -> Void

    private let encode: (State) throws -> Data
    private let decode: (Data) throws -> any Stored

    /// Initializes a `Substate` with a key path to a persistent substate of a larger state.
    ///
    /// - Parameter keyPath: The writable key path from the larger `State` to the specific substate.
    public init<Value: Stored>(
        key: String? = nil,
        _ keyPath: WritableKeyPath<State, Value>
    ) {
        self.key = key ?? Value.storageKey

        self.read = { state in
            state[keyPath: keyPath]
        }

        self.write = { state, value in
            guard let value = value as? Value else {
                fatalError(
                    "Invalid substate type \(type(of: value)) for keyPath \(keyPath)."
                )
            }
            state[keyPath: keyPath] = value
        }

        self.encode = { state in
            return try Value.encode(state[keyPath: keyPath])
        }

        self.decode = { data in
            return try Value.decode(data)
        }
    }

    /// Reads the substate from the provided state.
    ///
    /// - Parameter state: The larger state containing the substate.
    /// - Returns: The `PersistentState` object representing the substate.
    func read(from state: State) -> any Stored {
        return read(state)
    }

    /// Writes a `PersistentState` object into the provided state.
    ///
    /// - Parameters:
    ///   - state: The larger state to which the substate belongs.
    ///   - value: The `PersistentState` object to write to the substate.
    func write(to state: inout State, value: any Stored) {
        write(&state, value)
    }

    /// Encodes the substate from the provided state into JSON data.
    ///
    /// - Parameter state: The larger state containing the substate.
    /// - Returns: JSON-encoded data representing the substate.
    /// - Throws: An error if encoding fails.
    func encode(from state: State) throws -> Data {
        return try encode(state)
    }

    /// Decodes JSON data into a `PersistentState` object.
    ///
    /// - Parameter data: The JSON data to decode.
    /// - Returns: A `PersistentState` object representing the decoded substate.
    /// - Throws: An error if decoding fails.
    func decode(from data: Data) throws -> any Stored {
        return try decode(data)
    }
}

