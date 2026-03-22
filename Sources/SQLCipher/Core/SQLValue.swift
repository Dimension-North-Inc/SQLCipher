//
//  SQLValue.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 1/30/25.
//  Copyright © 2025 Dimension North Inc. All rights reserved.
//

import CSQLCipher
import Foundation

/// Represents a value that can be stored in SQLite.
public enum SQLValue: Hashable {
    /// Integer value stored as `Int64`.
    case integer(Int64)

    /// Floating-point value stored as `Double`.
    case real(Double)

    /// Text value stored as `String`.
    case text(String)

    /// Binary data stored as `Data`.
    case blob(Data)

    /// Null value representing an absence of data.
    case null

    /// Array of `SQLValue` elements.
    ///
    /// This case is primarily used to represent a collection of values that can be
    /// used in SQLite queries, such as `IN (:values)` clauses. Since SQLite lacks
    /// native support for arrays, this type allows collections of values (e.g., `[Int]`,
    /// `[String]`, etc.) to be passed as a single query parameter.
    ///
    /// Example usage:
    /// ```swift
    /// let values: SQLValue = .array([.integer(1), .integer(2), .integer(3)])
    /// db.execute("SELECT * FROM users WHERE id IN (:values)", parameters: ["values": values])
    /// ```
    indirect case array([SQLValue])

    /// Vector of floating-point values for use with sqlite-vec.
    ///
    /// Vectors are stored as a tuple of element type and packed blob data.
    case vector(VectorElementType, Data)
}

/// Element types supported by sqlite-vec for vector storage.
public enum VectorElementType: Int, Sendable {
    case float32 = 223  // SQLITE_VEC_ELEMENT_TYPE_FLOAT32
    case bit = 224     // SQLITE_VEC_ELEMENT_TYPE_BIT
    case int8 = 225    // SQLITE_VEC_ELEMENT_TYPE_INT8

    /// Returns the SQLite subtype value for this element type.
    public var sqliteSubtype: Int32 { Int32(rawValue) }
}

/// A type that can be used as the element type for a vector.
/// Conforming types provide packing and unpacking logic for storing
/// vector data as blobs in SQLite.
public protocol SQLVectorType: Hashable {
    /// The sqlite-vec element type for this vector type.
    static var elementType: VectorElementType { get }

    /// Packs an array of elements into Data for blob storage.
    static func pack(_ elements: [Self]) -> Data

    /// Unpacks Data back into an array of elements.
    static func unpack(_ data: Data) -> [Self]
}

extension SQLValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .integer(let value):
            return "\(value)"
        case .real(let value):
            return "\(value)"
        case .text(let value):
            return "'\(value)'"
        case .blob(let value):
            return value.description
        case .null:
            return "NULL"
        case .array(let values):
            return values.description
        case .vector(let elementType, let data):
            return "vector(\(elementType), \(data.count) bytes)"
        }
    }
}
extension SQLValue: Encodable {
    public func encode(to encoder: any Encoder) throws {
        if case .array(let values) = self {
            var container = encoder.unkeyedContainer()
            try container.encode(contentsOf: values)

        } else {
            var container = encoder.singleValueContainer()
            switch self {
            case .integer(let value):
                try container.encode(value)
            case .real(let value):
               try container.encode(value)
            case .text(let value):
                try container.encode(value)
            case .blob(let value):
                try container.encode(value)
            case .null:
                try container.encodeNil()
            case .vector(_, let data):
                // Vectors are stored as opaque blob data, not directly encodable as JSON
                try container.encode(data)
            default:
                break
            }
        }
    }
}

extension SQLValue {
    /// Creates a `SQLValue` from an SQLite statement at the given column index.
    ///
    /// - Parameters:
    ///   - statement: The SQLite statement pointer (`OpaquePointer`).
    ///   - col: The column index to extract.
    public init(stmt statement: OpaquePointer, col index: Int32) {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            self = .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            self = .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            if let textPtr = sqlite3_column_text(statement, index) {
                self = .text(String(cString: textPtr))
            } else {
                self = .null
            }
        case SQLITE_BLOB:
            let dataSize = sqlite3_column_bytes(statement, index)
            if let blobPtr = sqlite3_column_blob(statement, index) {
                self = .blob(Data(bytes: blobPtr, count: Int(dataSize)))
            } else {
                self = .null
            }
        default:
            self = .null
        }
    }
}

extension SQLValue {
    /// Binds the `SQLValue` to a SQLite statement at a specific index.
    ///
    /// - Parameters:
    ///   - statement: The prepared SQLite statement (`OpaquePointer`).
    ///   - index: The 1-based index at which to bind the value.
    ///   - db: The database handle, used for rich error reporting.
    /// - Throws: If binding fails.
    public func bind(to statement: OpaquePointer, at index: Int32, on db: OpaquePointer?) throws {
        let result: Int32
        
        switch self {
        case .integer(let value):
            result = sqlite3_bind_int64(statement, index, value)
        case .real(let value):
            result = sqlite3_bind_double(statement, index, value)
        case .text(let value):
            result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        case .blob(let value):
            // SQLite uses int32_t for blob size - blobs cannot exceed 2GB
            // Large files (video > 2GB) should be stored externally, not in database
            let byteCount = value.count
            guard byteCount <= Int(Int32.max) else {
                throw SQLiteError.general(
                    code: SQLITE_TOOBIG,
                    message: "Blob size (\(byteCount) bytes) exceeds SQLite's 2GB limit"
                )
            }
            result = sqlite3_bind_blob(statement, index, (value as NSData).bytes, Int32(byteCount), SQLITE_TRANSIENT)
        case .null:
            result = sqlite3_bind_null(statement, index)
        case .array(let values):
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(values)

            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                throw SQLiteError.general(code: SQLITE_ERROR, message: "\(#function) unable to convert array to JSON string")
            }

            result = sqlite3_bind_text(statement, index, jsonString, -1, SQLITE_TRANSIENT)
        case .vector(_, let data):
            // Vectors are stored as blob data for sqlite-vec compatibility
            result = sqlite3_bind_blob(statement, index, (data as NSData).bytes, Int32(data.count), SQLITE_TRANSIENT)
        }
        
        try checked(result, on: db)
    }
}

/// A type that can be represented as an `SQLValue`.
public protocol SQLValueRepresentable {
    /// Converts the value to an `SQLValue`.
    var sqliteValue: SQLValue { get }
    
    /// Initializes an instance from an `SQLValue`.
    /// - Parameter sqliteValue: The SQLite value to convert.
    init?(sqliteValue: SQLValue)
}

// MARK: - Basic Conformances

extension Int: SQLValueRepresentable {
    public var sqliteValue: SQLValue { .integer(Int64(self)) }
    
    public init?(sqliteValue: SQLValue) {
        switch sqliteValue {
        case .integer(let value):
            self = Int(value)
        case .real(let value):
            self = Int(value)
        default:
            return nil
        }
    }
}

extension Int64: SQLValueRepresentable {
    public var sqliteValue: SQLValue { .integer(self) }
    
    public init?(sqliteValue: SQLValue) {
        guard case .integer(let value) = sqliteValue else { return nil }
        self = value
    }
}

extension Float: SQLValueRepresentable {
    public var sqliteValue: SQLValue { .real(Double(self)) }

    public init?(sqliteValue: SQLValue) {
        switch sqliteValue {
        case .real(let value):
            self = Float(value)
        case .integer(let value):
            self = Float(value)
        default:
            return nil
        }
    }
}

/// Float (Float32) extension for sqlite-vec float32 vector storage.
/// Stores elements as 4-byte big-endian floats.
extension Float: SQLVectorType {
    public static let elementType = VectorElementType.float32

    public static func pack(_ elements: [Float]) -> Data {
        var result = Data(capacity: elements.count * 4)
        for value in elements {
            let bigEndian = value.bitPattern.bigEndian
            withUnsafeBytes(of: bigEndian) { result.append(contentsOf: $0) }
        }
        return result
    }

    public static func unpack(_ data: Data) -> [Float] {
        var elements: [Float] = []
        let count = data.count / 4
        for i in 0..<count {
            let offset = i * 4
            let bits = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }
            elements.append(Float(bitPattern: bits))
        }
        return elements
    }
}

/// Int8 extension for sqlite-vec int8 vector storage.
/// Stores elements as raw Int8 bytes.
extension Int8: SQLVectorType {
    public static let elementType = VectorElementType.int8

    public static func pack(_ elements: [Int8]) -> Data {
        Data(elements.map { UInt8(bitPattern: $0) })
    }

    public static func unpack(_ data: Data) -> [Int8] {
        data.map { Int8(bitPattern: $0) }
    }
}

/// Bool extension for sqlite-vec bit vector storage.
/// Stores elements as packed bits (8 bools per byte, MSB first).
extension Bool: SQLVectorType {
    public static let elementType = VectorElementType.bit

    public static func pack(_ elements: [Bool]) -> Data {
        var result = Data()
        var index = 0
        while index < elements.count {
            var byte: UInt8 = 0
            for bitIndex in 0..<8 {
                if index + bitIndex < elements.count && elements[index + bitIndex] {
                    byte |= (1 << (7 - bitIndex))
                }
            }
            result.append(byte)
            index += 8
        }
        return result
    }

    public static func unpack(_ data: Data) -> [Bool] {
        var elements: [Bool] = []
        for byte in data {
            for index in 0..<8 {
                elements.append((byte & (1 << (7 - index))) != 0)
            }
        }
        return elements
    }
}

extension Double: SQLValueRepresentable {
    public var sqliteValue: SQLValue { .real(self) }
    
    public init?(sqliteValue: SQLValue) {
        switch sqliteValue {
        case .real(let value):
            self = value
        case .integer(let value):
            self = Double(value)
        default:
            return nil
        }
    }
}

extension String: SQLValueRepresentable {
    public var sqliteValue: SQLValue { .text(self) }
    
    public init?(sqliteValue: SQLValue) {
        guard case .text(let value) = sqliteValue else { return nil }
        self = value
    }
}

extension Data: SQLValueRepresentable {
    public var sqliteValue: SQLValue { .blob(self) }
    
    public init?(sqliteValue: SQLValue) {
        guard case .blob(let value) = sqliteValue else { return nil }
        self = value
    }
}

extension Bool: SQLValueRepresentable {
    public var sqliteValue: SQLValue { .integer(self ? 1 : 0) }

    public init?(sqliteValue: SQLValue) {
        switch sqliteValue {
        case .integer(let value):
            self = value != 0
        case .real(let value):
            self = value != 0
        default:
            return nil
        }
    }
}

extension Date: SQLValueRepresentable {
    /// An SQLite-compatible ISO 8601 date format (full datetime).
    private static let sqliteFormat = ISO8601FormatStyle()
        .dateSeparator(.dash)
        .timeSeparator(.colon)
        .dateTimeSeparator(.standard)

    public var sqliteValue: SQLValue {
        .text(self.formatted(Self.sqliteFormat))
    }

    public init?(sqliteValue: SQLValue) {
        switch sqliteValue {
        case .text(let value):
            if let date = try? Self.sqliteFormat.parse(value) {
                self = date
            } else {
                return nil
            }
        case .real(let value):
            self = Date(timeIntervalSinceReferenceDate: value)
        case .integer(let value):
            self = Date(timeIntervalSinceReferenceDate: Double(value))
        default:
            return nil
        }
    }
}

extension UUID: SQLValueRepresentable {
    public var sqliteValue: SQLValue {
        .text(self.uuidString)
    }
    
    public init?(sqliteValue: SQLValue) {
        guard case .text(let value) = sqliteValue else { return nil }
        self.init(uuidString: value)
    }
}

// MARK: - Collection Conformances

extension Optional: SQLValueRepresentable where Wrapped: SQLValueRepresentable {
    public var sqliteValue: SQLValue {
        switch self {
        case .none:
            return .null
        case .some(let value):
            return value.sqliteValue
        }
    }
    
    public init?(sqliteValue: SQLValue) {
        switch sqliteValue {
        case .null:
            self = .none
        default:
            guard let value = Wrapped(sqliteValue: sqliteValue) else { return nil }
            self = .some(value)
        }
    }
}

extension Set: SQLValueRepresentable where Element: SQLValueRepresentable {
    public var sqliteValue: SQLValue {
        .array(map(\.sqliteValue))
    }
    
    public init?(sqliteValue: SQLValue) {
        guard case let .array(values) = sqliteValue else { return nil }
        self = Set(values.compactMap(Element.init(sqliteValue:)))
    }
}

extension Array: SQLValueRepresentable where Element: SQLValueRepresentable {
    public var sqliteValue: SQLValue {
        .array(map(\.sqliteValue))
    }

    public init?(sqliteValue: SQLValue) {
        guard case let .array(values) = sqliteValue else { return nil }
        self = values.compactMap(Element.init(sqliteValue:))
    }
}

// MARK: - Vector Support

/// A wrapper type for vector embeddings that provides SQLValueRepresentable conformance.
/// The element type `Value` determines the storage format (float32, int8, or bit).
public struct Vector<Value: SQLVectorType>: SQLValueRepresentable, Hashable {
    public let elements: [Value]

    public init(_ elements: [Value]) {
        self.elements = elements
    }

    public init?(sqliteValue: SQLValue) {
        guard case let .vector(elementType, data) = sqliteValue,
              elementType == Value.elementType else {
            return nil
        }
        self.elements = Value.unpack(data)
    }

    public var sqliteValue: SQLValue {
        .vector(Value.elementType, Value.pack(elements))
    }

    public var count: Int { elements.count }
    public var isEmpty: Bool { elements.isEmpty }

    public subscript(index: Int) -> Value {
        elements[index]
    }
}

extension Vector: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Value...) {
        self.init(elements)
    }
}

// MARK: - RawRepresentable Conformance

extension RawRepresentable where RawValue: SQLValueRepresentable {
    public var sqliteValue: SQLValue {
        rawValue.sqliteValue
    }
    
    public init?(sqliteValue: SQLValue) {
        guard
            let rawValue = RawValue(sqliteValue: sqliteValue),
            let value = Self(rawValue: rawValue)
        else {
            return nil
        }
        self = value
    }
}

// MARK: - Codable Conformance

extension SQLValueRepresentable where Self: Codable {
    public var sqliteValue: SQLValue {
        if let data = try? JSONEncoder().encode(self) {
            return .blob(data)
        } else {
            return .null
        }
    }
    
    public init?(sqliteValue: SQLValue) {
        if case let .blob(data) = sqliteValue,
           let value = try? JSONDecoder().decode(Self.self, from: data) {
            self = value
        } else {
            return nil
        }
    }
}

/// A constant used to inform SQLite that it should make a copy of the text
/// or blob data when binding. This is necessary for transient data that will
/// not persist beyond the scope of the SQLite statement execution.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
