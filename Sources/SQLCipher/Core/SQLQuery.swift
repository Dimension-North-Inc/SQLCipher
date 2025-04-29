//
//  SQLQuery.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 2/11/25.
//  Copyright © 2025 Dimension North Inc. All rights reserved.

import Foundation

import CSQLCipher

/**
 A type‑safe SQL query builder that uses a DSL to compose SQL queries with named parameters.

 The `SQLQuery` type leverages a result builder to provide a concise DSL for composing SQL query fragments.
 For simpler query expressions, `SQLQuery` also conforms to `ExpressibleByStringInterpolation`.

 Both query building mechanisms  automatically handle parameter naming, parameter extraction, and insertion
 of spaces between fragments.
 
 ## The SQLQuery DSL

 `SQLQuery` allows you to build parameterized SQL queries in a type‑safe way. The DSL is designed to integrate
 seamlessly with your model types. In the DSL block you can use raw string literals as SQL fragments as well as
 helper methods that create parameters. Parameters can be provided via key paths or closures, and the DSL
 automatically substitutes temporary tokens with final named placeholders.

 For example, consider the following model:

     struct User {
         let id: Int
         let email: String
     }
 
 You can build a SQL query for the model as follows:
 
     let query: SQLQuery<User> = SQLQuery {
         "SELECT * FROM users WHERE id ="
         param(\.id)
         "AND email ="
         param({ $0.email }, named: "email")
     }
     
     let user = User(id: 42, email: "alice@example.com")
     print(query.sql)
     // Prints something like: "SELECT * FROM users WHERE id = :p1 AND email = :email"
     
     let params = query.params(from: user)
     // Result: ["p1": 42, "email": "alice@example.com"]
 

 The DSL automatically inserts spaces between fragments (if needed) so you need not worry about
 manually adding whitespace between your raw SQL literals and parameters.

 ## String Interpolation Support

 `SQLQuery` also conforms to `ExpressibleByStringInterpolation`, enabling you to embed parameters directly
 in a multi-line string literal. Each interpolation generates an anonymous parameter (`:p1`, `:p2`, …)
 and binds its value automatically:

 Using direct value interpolation:

        let q: SQLQuery<Void> = """
        let value: Int = 42
        INSERT INTO counter (count) VALUES (\(value));
        """

 Using key-path interpolation:

        struct P { var id: UUID }
        let q: SQLQuery<P> = """
        DELETE FROM sessions WHERE session_id = \(\.id);
        """

 Or using closure-based interpolation:

        let q: SQLQuery<User> = """
        UPDATE users
        SET last_login = \({ $0.now })
        WHERE id = \(\.id);
        """

 ## IMPORTANT
 Raw `:named` placeholders in string literals are *not* recognized. Only parameters
 registered via the DSL (`param(...)`) or via interpolation (`\(...)`) are bound.
 
 ## See Also

 - `SQLValue` – the type representing SQL values.
 - `SQLValueRepresentable` – protocols for types that can be converted to an `SQLValue`.
 */
public struct SQLQuery<Params> {
    /// The finalized SQL string with placeholders (e.g. ":p1" or with explicit names).
    public let sql: String
    /// A mapping of final parameter names to their extraction closures.
    private let extractors: [String: (Params) -> SQLValue]
    
    /**
     Initializes a new SQL query by composing fragments produced within the DSL block.
     
     The DSL block is annotated with `@Builder` and allows you to combine raw SQL strings and parameter
     fragments. Temporary tokens in the SQL are replaced by final named placeholders using either explicit names
     or auto‑generated ones.
     
     - Parameter content: A closure that returns a `Fragment` representing the composed SQL query.
    */
    public init(@Builder _ content: () -> Fragment) {
        let fragment = content()
        var finalSQL = fragment.sql
        var extractors: [String: (Params) -> SQLValue] = [:]
        var autoCounter = 1
        
        for def in fragment.parameters {
            let finalName: String = def.name ?? {
                defer { autoCounter += 1 }
                return "p\(autoCounter)"
            }()
            finalSQL = finalSQL.replacingOccurrences(of: def.token, with: ":\(finalName)")
            extractors[finalName] = def.extractor
        }
        
        self.sql = rewriteInClauses(sql: finalSQL)
        self.extractors = extractors
    }
    
    /**
     Extracts the query parameters from a given container.
     
     This method applies each of the extractor closures stored in the query to the provided container.
     
     - Parameter container: A model instance or container conforming to the requirements for parameter binding.
     - Returns: A dictionary mapping parameter names to their corresponding SQL values.
     */
    public func params(from container: Params) -> [String: SQLValue] {
        var result: [String: SQLValue] = [:]
        for (name, extractor) in extractors {
            result[name] = extractor(container)
        }
        return result
    }
    
    // MARK: - Nested Types
    
    /**
     An individual parameter definition for a SQL query.
     
     Each parameter represents a portion of the SQL that will eventually be replaced by a named placeholder.
     It contains an optional explicit name, a temporary token string that appears in the SQL fragment,
     and an extractor closure to retrieve the parameter’s value from a container.
     */
    public struct Parameter {
        /// An explicit name for the parameter (if provided).
        public let name: String?
        /// A temporary token that will be replaced with a final placeholder in the SQL string.
        public let token: String
        /// An extractor closure that returns the SQL value from a given container.
        public let extractor: (Params) -> SQLValue
        
        /**
         Creates a new parameter definition.
         
         - Parameters:
           - name: An explicit parameter name. If nil, an auto‑generated name will be used.
           - token: A temporary token that appears in the SQL fragment.
           - extractor: A closure that extracts a parameter value from a container.
         */
        public init(name: String?, token: String, extractor: @escaping (Params) -> SQLValue) {
            self.name = name
            self.token = token
            self.extractor = extractor
        }
    }
    
    /**
     A fragment represents a piece of SQL along with any associated parameter definitions.
     
     Fragments are the building blocks for composing a full SQL query and may either represent
     raw SQL text or parameterized parts generated via helper methods.
     */
    public struct Fragment {
        /// The raw or intermediate SQL string which may include temporary tokens.
        public let sql: String
        /// An array of parameter definitions embedded in this fragment.
        public let parameters: [Parameter]
        
        /**
         Creates a new SQL fragment.
         
         - Parameters:
           - sql: The SQL text for the fragment.
           - parameterDefs: An array of parameters associated with the fragment (default is an empty array).
         */
        public init(sql: String, parameters: [Parameter] = []) {
            self.sql = sql
            self.parameters = parameters
        }
        
        /// Emits a raw SQL fragment.
        static func raw(_ string: String) -> Self {
            Fragment(sql: string)
        }
        
        /**
         Creates a parameter fragment based on a key path.
         
         The method creates a unique temporary token and a parameter definition that extracts
         a value from the container using the given key path.
         
         - Parameters:
           - keyPath: A key path into the container.
           - named: An optional explicit name for the parameter. If nil, a name will be auto‑generated.
         - Returns: A fragment that represents this parameter.
         */
        static func param<Value: SQLValueRepresentable>(
            _ keyPath: KeyPath<Params, Value>,
            named name: String? = nil
        ) -> Self {
            let token = "__PARAM_\(UUID().uuidString)__"
            let def = Parameter(name: name, token: token, extractor: { container in
                container[keyPath: keyPath].sqliteValue
            })
            return Fragment(sql: token, parameters: [def])
        }
        
        /**
         Creates a parameter fragment based on a value provider closure.
         
         This method enables you to supply a closure that extracts a parameter value from the container.
         
         - Parameters:
           - valueProvider: A closure that returns the parameter value from the container.
           - named: An optional explicit name for the parameter.
         - Returns: A fragment that represents this parameter.
         */
        static func param<Value: SQLValueRepresentable>(
            _ valueProvider: @escaping (Params) -> Value,
            named name: String? = nil
        ) -> Self {
            let token = "__PARAM_\(UUID().uuidString)__"
            let def = Parameter(name: name, token: token, extractor: { container in
                valueProvider(container).sqliteValue
            })
            return Fragment(sql: token, parameters: [def])
        }
    }
    
    // MARK: - DSL Result Builder
    
    /**
     A result builder that composes SQL query fragments.
     
     The builder automatically concatenates raw SQL string fragments while inserting a space between them
     when needed. It also converts string literals into raw SQL fragments.
     */
    @resultBuilder
    public struct Builder {
        /**
         Combines multiple SQL fragments into a single SQL string.
         
         Inserts a space between fragments if the previous fragment does not end with whitespace
         and the next fragment does not begin with whitespace.
         
         - Parameter components: An array of fragments.
         - Returns: A single combined SQL string.
         */
        private static func combineFragments(_ components: [Fragment]) -> String {
            var result = ""
            for fragment in components {
                if !result.isEmpty {
                    if let lastChar = result.last, let firstChar = fragment.sql.first,
                       !lastChar.isWhitespace && !firstChar.isWhitespace {
                        result.append(" ")
                    }
                }
                result.append(fragment.sql)
            }
            return result
        }
        
        /**
         Builds a complete fragment from multiple fragments.
         
         - Parameter components: A variadic list of fragments.
         - Returns: A combined `Fragment` with merged SQL and parameter definitions.
         */
        public static func buildBlock(_ components: Fragment...) -> Fragment {
            let combinedSQL = combineFragments(components)
            let combinedDefs = components.flatMap { $0.parameters }
            return Fragment(sql: combinedSQL, parameters: combinedDefs)
        }
        
        /**
         Converts a raw string literal into a SQL fragment.
         
         - Parameter expression: A raw SQL string.
         - Returns: A `Fragment` representing the raw SQL.
         */
        public static func buildExpression(_ expression: String) -> Fragment {
            Fragment(sql: expression)
        }
        
        public static func buildExpression(_ fragment: Fragment) -> Fragment {
            fragment
        }
        
        public static func buildExpression<Value: SQLValueRepresentable>(_ value: Value) -> Fragment {
            let token = "__PARAM_\(UUID().uuidString)__"
            let def = Parameter(name: nil, token: token) { _ in value.sqliteValue }
            return Fragment(sql: token, parameters: [def])
        }
        
        public static func buildOptional(_ component: Fragment?) -> Fragment {
            component ?? Fragment(sql: "")
        }
        
        public static func buildEither(first component: Fragment) -> Fragment {
            component
        }
        
        public static func buildEither(second component: Fragment) -> Fragment {
            component
        }
        
        public static func buildArray(_ components: [Fragment]) -> Fragment {
            let combinedSQL = combineFragments(components)
            let combinedDefs = components.flatMap { $0.parameters }
            return Fragment(sql: combinedSQL, parameters: combinedDefs)
        }
    }
}

extension SQLQuery: ExpressibleByStringInterpolation {
    public struct StringInterpolation: StringInterpolationProtocol {
        var fragments: [Fragment] = []
        
        public init(literalCapacity: Int, interpolationCount: Int) {
            fragments.reserveCapacity(literalCapacity + interpolationCount)
        }
        
        public mutating func appendLiteral(_ literal: String) {
            fragments.append(.raw(literal))
        }
        
        public mutating func appendInterpolation<Value: SQLValueRepresentable>(_ value: Value?) {
            let token = "__PARAM_\(UUID().uuidString)__"
            let def = Parameter(name: nil, token: token) { _ in
                guard let value else { return SQLValue.null }
                return value.sqliteValue
            }
            fragments.append(Fragment(sql: token, parameters: [def]))
        }
        
        public mutating func appendInterpolation<Value: SQLValueRepresentable>(_ value: Value) {
            let token = "__PARAM_\(UUID().uuidString)__"
            let def = Parameter(name: nil, token: token) { _ in value.sqliteValue }
            fragments.append(Fragment(sql: token, parameters: [def]))
        }
        
        // Support for key paths in parameterized queries
        public mutating func appendInterpolation<Value: SQLValueRepresentable>(
            _ keyPath: KeyPath<Params, Value>
        ) {
            fragments.append(param(keyPath))
        }
        
        // Support for closure-based parameter extraction
        public mutating func appendInterpolation<Value: SQLValueRepresentable>(
            _ valueProvider: @escaping (Params) -> Value
        ) {
            fragments.append(param(valueProvider))
        }
    }
    
    public init(stringLiteral value: String) {
        self.init { Fragment.raw(value) }
    }
    
    public init(stringInterpolation: StringInterpolation) {
        self.init {
            Builder.buildBlock(stringInterpolation.fragments.isEmpty
                             ? Fragment.raw("")
                             : Builder.buildArray(stringInterpolation.fragments))
        }
    }
}


// MARK: - Free Functions
/// Emits a raw SQL fragment.
public func raw<Params>(_ string: String) -> SQLQuery<Params>.Fragment {
    SQLQuery<Params>.Fragment(sql: string)
}

/**
 Creates a parameter fragment based on a key path.
 
 The method creates a unique temporary token and a parameter definition that extracts
 a value from the container using the given key path.
 
 - Parameters:
   - keyPath: A key path into the container.
   - named: An optional explicit name for the parameter. If nil, a name will be auto‑generated.
 - Returns: A fragment that represents this parameter.
 */
public func param<Params, Value: SQLValueRepresentable>(
    _ keyPath: KeyPath<Params, Value>,
    named name: String? = nil
) -> SQLQuery<Params>.Fragment {
    let token = "__PARAM_\(UUID().uuidString)__"
    let def = SQLQuery<Params>.Parameter(name: name, token: token, extractor: { container in
        container[keyPath: keyPath].sqliteValue
    })
    return SQLQuery<Params>.Fragment(sql: token, parameters: [def])
}

/**
 Creates a parameter fragment based on a value provider closure.
 
 This method enables you to supply a closure that extracts a parameter value from the container.
 
 - Parameters:
   - valueProvider: A closure that returns the parameter value from the container.
   - named: An optional explicit name for the parameter.
 - Returns: A fragment that represents this parameter.
 */
public func param<Params, Value: SQLValueRepresentable>(
    _ valueProvider: @escaping (Params) -> Value,
    named name: String? = nil
) -> SQLQuery<Params>.Fragment {
    let token = "__PARAM_\(UUID().uuidString)__"
    let def = SQLQuery<Params>.Parameter(name: name, token: token, extractor: { container in
        valueProvider(container).sqliteValue
    })
    return SQLQuery<Params>.Fragment(sql: token, parameters: [def])
}

public typealias SQLStaticQuery = SQLQuery<Void>


extension SQLQuery {
    public func prepared(for connection: SQLConnection) throws -> SQLPreparedQuery<Params> {
        return try SQLPreparedQuery(
            connection: connection, query: self, stmt: compile(sql: sql, db: connection.db)
        )
    }
}

public final class SQLPreparedQuery<Params> {
    let connection: SQLConnection
    let query: SQLQuery<Params>
    
    let stmt: OpaquePointer
    
    init(connection: SQLConnection, query: SQLQuery<Params>, stmt: OpaquePointer) {
        self.connection = connection
        self.query = query
        self.stmt = stmt
    }
    
    deinit {
        sqlite3_finalize(stmt)
    }
    
    @discardableResult
    func execute(_ params: Params) throws -> SQLResult {
        try connection.queue.sync {
            defer {
                sqlite3_reset(stmt)
            }
            
            // Extract and bind parameters
            let sqliteParams = query.params(from: params)
            for (key, value) in sqliteParams {
                let index = sqlite3_bind_parameter_index(stmt, ":\(key)")
                if index > 0 { try value.bind(to: stmt, at: index) }
            }
            
            SQLConnection.log.debug(
                "executing: \(self.query.sql, privacy: .public), params: \(sqliteParams, privacy: .public)"
            )
            
            // Collect rows
            var rows: [SQLRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(SQLRow(statement: stmt))
            }
            
            // Get result metadata
            let count = sqlite3_changes(connection.db)
            let lastID = sqlite3_last_insert_rowid(connection.db)
            
            return SQLResult(rows: rows, affectedRows: count, lastInsertedRowID: lastID)
        }
    }
    
    @discardableResult
    func execute() throws -> SQLResult where Params == Void {
        try execute(())
    }
}

/// Rewrites IN clauses to use json_each to bind multiple values.
///
/// IN clauses written `WHERE bar IN (:list_of_values)` are
/// rewritten to `WHERE bar IN (SELECT value FROM json_each(:list_of_values))`.
///
/// - Parameter sql: a SQL statement
/// - Returns: a modified SQL statement
private func rewriteInClauses(sql: String) -> String {
    let pattern = /(?i)IN\s*\(\s*:(\w+)\s*\)/
    return sql.replacing(pattern) { match in
        "IN (SELECT value FROM json_each(:\(match.1)))"
    }
}

/// Compiles and returns an SQL statement, or throws on failure.
/// - Parameters:
///   - sql: a SQL statement
///   - db: a database connection
/// - Throws: an SQLError
/// - Returns: a compiled SQL statement
private func compile(sql: String, db: OpaquePointer) throws -> OpaquePointer {
    var stmt: OpaquePointer?
    try checked(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
    guard let stmt else {
        throw SQLError(misuse: "\(#function) failed to compile SQL statement")
    }
    
    return stmt
}

