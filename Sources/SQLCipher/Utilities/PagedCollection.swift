//
//  PagedCollection.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 11/7/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import SwiftUI

/// A protocol defining the requirements for a data source that supports paged data fetching.
public protocol PagedDataSource {
    associatedtype Element

    /// The total number of elements available in the data source.
    var count: Int { get }

    /// Fetches a page of elements synchronously.
    /// - Parameters:
    ///   - startIndex: The starting index for the page.
    ///   - count: The number of elements to fetch.
    /// - Returns: An array of elements from the specified page.
    func fetch(startIndex: Int, count: Int) -> [Element]
}

/// A collection type that provides random access to elements in a paged data source.
/// `PagedCollection` loads pages of data on demand, caching loaded pages for faster subsequent access.
///
/// - Note: This collection fetches pages of data from a `PagedDataSource` synchronously.
///   This makes it ideal for scenarios where each page load is fast and does not require asynchronous handling.
public final class PagedCollection<DataSource: PagedDataSource>: RandomAccessCollection {
    public typealias Index = Int
    public typealias Element = DataSource.Element

    /// Represents the state of a page in the collection.
    public enum Page {
        /// A loaded page containing elements.
        case loaded([Element])
        /// An unloaded page representing a range of indices.
        case unloaded(Range<Int>)
    }

    private var pages: [Page]
    private let pageSize: Int
    private let dataSource: DataSource

    /// Initializes a `PagedCollection` with a specified data source and page size.
    ///
    /// - Parameters:
    ///   - dataSource: The data source from which to fetch pages.
    ///   - pageSize: The number of elements per page. Defaults to 20.
    public init(dataSource: DataSource, pageSize: Int = 20) {
        self.dataSource = dataSource
        self.pageSize = pageSize
        
        let totalPages = (dataSource.count + pageSize - 1) / pageSize
        
        self.pages = (0 ..< totalPages).map { index in
            Page.unloaded(
                (index * pageSize) ..< Swift.min((index + 1) * pageSize, dataSource.count)
            )
        }
    }

    /// The start index of the collection, always zero.
    public var startIndex: Int { 0 }
    
    /// The end index of the collection, representing the total number of elements in the data source.
    public var endIndex: Int { dataSource.count }

    /// Accesses the element at the specified position, loading the page if it hasn’t been loaded.
    ///
    /// - Parameter position: The index of the element to access.
    /// - Returns: The element at the specified index.
    public subscript(position: Index) -> Element {
        let pageIndex = position / pageSize
        let localIndex = position % pageSize
        
        switch pages[pageIndex] {
        case .loaded(let elements):
            return elements[localIndex]
            
        case .unloaded(let range):
            let elements = dataSource.fetch(startIndex: range.lowerBound, count: range.count)
            pages[pageIndex] = .loaded(elements)
            return elements[localIndex]
        }
    }
}
