//
//  PagedSQLCipherDataSource.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 11/7/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import SQLCipher

/// A data source that fetches paginated results from an SQLCipher database, using
/// a customizable SQL query with named parameter substitution.
public final class PagedSQLCipherDataSource: PagedDataSource {
    public typealias Element = SQLRow
    
    private let db: Database
    
    private let query: String
    private let substitutions: [String: SQLValue]
    
    private let pageSize: Int
    private var cachedCount: Int? = nil
    
    /// Initializes a new `PagedSQLCipherDataSource` with the specified database, query, substitutions, and page size.
    ///
    /// - Parameters:
    ///   - db: The database instance to execute the query on.
    ///   - query: The SQL query to retrieve data, excluding pagination (`LIMIT` and `OFFSET`).
    ///   - substitutions: A dictionary of named parameters to substitute in the query.
    ///   - pageSize: The number of rows per page. Defaults to 20.
    public init(db: Database, query: String, substitutions: [String: SQLValue] = [:], pageSize: Int = 20) {
        self.db = db

        self.query = query
        self.substitutions = substitutions

        self.pageSize = pageSize
    }
    
    /// The total count of elements matching the query. This value is cached after the first access.
    ///
    /// - Returns: The total number of rows for the given query and substitutions.
    public var count: Int {
        if let cachedCount = cachedCount {
            return cachedCount
        }
        
        let countQuery = "SELECT COUNT(*) AS count FROM (\(query))"
        do {
            if let row = try db.execute(countQuery, substitutions).first,
               let count = row["count"]?.numberValue {
                let value = Int(count)
                cachedCount = value
                return value
            } else {
                return 0
            }
        } catch {
            print("Error fetching count: \(error)")
            return 0
        }
    }
    
    /// Fetches a page of elements synchronously, using the specified `startIndex` and `count`.
    ///
    /// - Parameters:
    ///   - startIndex: The starting index for the page.
    ///   - count: The number of elements to fetch.
    /// - Returns: An array of `SQLRow` elements representing the page of data.
    public func fetch(startIndex: Int, count: Int) -> [Element] {
        let pagedQuery = "\(query) LIMIT \(count) OFFSET \(startIndex)"
        
        do {
            return try db.execute(pagedQuery, substitutions)
        } catch {
            print("Error fetching page: \(error)")
            return []
        }
    }
    
    /// Maps the results of this data source to a new `MappedSQLCipherDataSource`, transforming `SQLRow` elements to an arbitrary type.
    ///
    /// - Parameter transform: A closure that converts an `SQLRow` into the desired mapped type.
    /// - Returns: A `MappedSQLCipherDataSource` instance that fetches and transforms data.
    public func map<MappedElement>(_ transform: @escaping (SQLRow) -> MappedElement) -> some PagedDataSource {
        return MappedSQLCipherDataSource(baseDataSource: self, transform: transform)
    }
}

/// A data source that transforms rows from an underlying `PagedSQLCipherDataSource`
/// into an arbitrary model type using a specified transformation closure.
public final class MappedSQLCipherDataSource<Element>: PagedDataSource {
    private let baseDataSource: PagedSQLCipherDataSource
    private let transform: (SQLRow) -> Element
    
    /// Initializes a `MappedSQLCipherDataSource` with the specified base data source and transformation closure.
    ///
    /// - Parameters:
    ///   - baseDataSource: The underlying `PagedSQLCipherDataSource` to fetch raw rows from.
    ///   - transform: A closure that converts `SQLRow` elements into the desired mapped type.
    public init(baseDataSource: PagedSQLCipherDataSource, transform: @escaping (SQLRow) -> Element) {
        self.baseDataSource = baseDataSource
        self.transform = transform
    }
    
    /// The total count of elements in the underlying data source.
    ///
    /// - Returns: The total count of rows in the base data source, before transformation.
    public var count: Int {
        baseDataSource.count
    }
    
    /// Fetches a page of transformed elements synchronously.
    ///
    /// - Parameters:
    ///   - startIndex: The starting index for the page.
    ///   - count: The number of elements to fetch.
    /// - Returns: An array of transformed elements of the specified type.
    public func fetch(startIndex: Int, count: Int) -> [Element] {
        let rows = baseDataSource.fetch(startIndex: startIndex, count: count)
        return rows.map(transform)
    }
}
