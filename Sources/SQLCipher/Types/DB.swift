//
//  DB.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 10/15/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import Foundation
import CSQLCipher

/// A protocol defining the basic database operations available to database readers and writers.
/// Conforming types provide methods for executing SQL commands and queries with both positional
/// and named parameters.
public protocol DB {
    
    /// Begins a new transaction in the database.
    ///
    /// This method initiates a transaction, grouping multiple database operations
    /// into a single atomic operation. Changes made during the transaction are not
    /// saved to the database until a `commit` is executed. If an error occurs
    /// during the transaction, `rollback` can be used to revert changes.
    ///
    /// - Throws: An error if the transaction cannot be started.
    func begin() throws
    
    /// Commits the current transaction to the database.
    ///
    /// This method saves all changes made during the transaction to the database.
    /// It finalizes the transaction that was started with `begin`. If `begin`
    /// was not called prior to this, calling `commit` may have no effect.
    ///
    /// - Throws: An error if the transaction cannot be committed, which may indicate
    ///   issues with the underlying database or constraints violated during the transaction.
    func commit() throws
    
    /// Rolls back the current transaction in the database.
    ///
    /// This method cancels all changes made during the current transaction, reverting
    /// the database to the state it was in before `begin` was called. This is useful
    /// for error recovery or if an operation within the transaction fails.
    ///
    /// - Throws: An error if the transaction cannot be rolled back.
    func rollback() throws

    /// Executes one or more SQL commands separated by semicolons.
    ///
    /// This method provides a convenient way to run multiple commands at once.
    /// Commands should be separated by semicolons (`;`), which indicates the end
    /// of each individual SQL statement.
    ///
    /// - Parameter sql: A string containing one or more SQL commands.
    /// - Throws: An error if the execution of any command fails.
    func exec(_ sql: String) throws
    
    /// Executes a SQL query with positional parameters and returns the resulting rows.
    ///
    /// The query may include positional placeholders (`?`) which are replaced by the values
    /// specified in the `values` parameter. The function returns an array of `Row` instances,
    /// representing each row returned by the query.
    ///
    /// - Parameters:
    ///   - sql: A SQL query containing positional placeholders.
    ///   - values: An array of `Value` instances to bind to the positional placeholders.
    /// - Returns: An array of `Row` objects representing the query result set.
    /// - Throws: An error if the query execution or parameter binding fails.
    func execute(_ sql: String, with values: [Value]) throws -> [Row]
    
    /// Executes a SQL query with named parameters and returns the resulting rows.
    ///
    /// The query may include named placeholders (e.g., `:name`) which are replaced by the values
    /// specified in the `namedValues` parameter. The function returns an array of `Row` instances,
    /// representing each row returned by the query.
    ///
    /// - Parameters:
    ///   - sql: A SQL query containing named placeholders.
    ///   - namedValues: A dictionary mapping placeholder names to `Value` instances.
    /// - Returns: An array of `Row` objects representing the query result set.
    /// - Throws: An error if the query execution or parameter binding fails.
    func execute(_ sql: String, with namedValues: [String: Value]) throws -> [Row]
}
