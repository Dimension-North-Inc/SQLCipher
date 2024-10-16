//
//  File.swift
//  CSQLCipher
//
//  Created by Mark Onyschuk on 10/16/24.
//

import Foundation

/// A protocol used to tag types that behave like optionals, allowing access to an underlying wrapped value.
public protocol OptionalType {
    /// The type of the value that is optionally wrapped.
    associatedtype Wrapped
    
    /// Provides access to the wrapped value if it exists, otherwise returns `nil`.
    var wrappedValue: Wrapped? { get }
}

/// Conform `Swift.Optional` to the `OptionalType` protocol.
///
/// This extension allows all standard `Optional` types to conform to the `OptionalType` protocol,
/// enabling generic handling of optionals within code that references `OptionalType`.
extension Optional: OptionalType {
    /// Accesses the wrapped value of the optional.
    ///
    /// - If the optional contains a value, `wrappedValue` returns that value.
    /// - If the optional is `nil`, `wrappedValue` returns `nil`.
    public var wrappedValue: Wrapped? { self }
}
