//
//  Stored.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 2/3/25.
//  Copyright © 2025 Dimension North Inc. All rights reserved.
//

import Foundation

/// Values stored within a SQLCipher database. Stored types must be both encodable
/// and decodable from a Data representation, and must be able to be checked for equality.
///
/// Default implementations of protocol methods for both Equatable and Codable types
/// means that most typical Swift types can simply be marked `Stored` without the need
/// for any futher custom code.
public protocol Stored: Sendable {
    /// Encodes the value into binary data for storage
    ///
    /// - Parameter value: The value to encode
    /// - Returns: The encoded data
    /// - Throws: An error if encoding fails
    static func encode(_ value: Self) throws -> Data

    /// Decodes binary data into a value
    ///
    /// - Parameter data: The binary data to decode
    /// - Returns: The decoded value
    /// - Throws: An error if decoding fails
    static func decode(_ data: Data) throws -> Self

    /// Determines equality with another `Stored` value.
    ///
    /// - Parameter other: Another `PersistentState` to compare.
    /// - Returns: A Boolean value indicating whether the two states are equal.
    func isEqual(to other: any Stored) -> Bool
}

extension Stored {
    /// A default storage key derived from the conforming type name.
    public static var storageKey: String {
        return String(describing: Self.self).lowercased()
    }
}

extension Stored where Self: Equatable {
    /// Default equality implementation using `Equatable`.
    ///
    /// - Parameter other: Another `PersistentState` to compare.
    /// - Returns: A Boolean value indicating whether the two states are equal.
    public func isEqual(to other: any Stored) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}

extension Stored where Self: Codable {
    /// Encodes a value into binary data using JSON encoding.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: The encoded data.
    /// - Throws: An error if encoding fails.
    public static func encode(_ value: Self) throws -> Data {
        return try JSONEncoder().encode(value)
    }

    /// Decodes binary data into a value using JSON decoding.
    ///
    /// - Parameter data: The data to decode.
    /// - Returns: The decoded value.
    /// - Throws: An error if decoding fails.
    public static func decode(_ data: Data) throws -> Self {
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
