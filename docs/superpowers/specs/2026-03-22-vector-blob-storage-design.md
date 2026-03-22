# Vector Blob Storage Design

## Context

SQLite's sqlite-vec extension supports vector storage with three element types: `float32`, `int8`, and `bit`. The current implementation uses `SQLValue.vector([Float])` which stores vectors as JSON strings—a format sqlite-vec does not natively consume.

This design replaces the JSON-based vector storage with proper blob storage that sqlite-vec expects, while providing a type-safe Swift API for working with vectors.

## Goal

- Replace `SQLValue.vector([Float])` with blob-backed storage via `SQLValue.vector(VectorElementType, Data)`
- Provide `Vector<Value>` parameterized by element type conforming to `SQLVectorType`
- Support all sqlite-vec element types: `float32`, `int8`, and `bit`
- Eliminate the special case handling in `SQLValue.bind(to:at:on:)`

## Design

### 1. VectorElementType Enum

```swift
public enum VectorElementType: Int {
    case float32 = 223  // Matches SQLITE_VEC_ELEMENT_TYPE_FLOAT32
    case bit = 224     // Matches SQLITE_VEC_ELEMENT_TYPE_BIT
    case int8 = 225    // Matches SQLITE_VEC_ELEMENT_TYPE_INT8

    public var sqliteSubtype: Int32 { Int32(rawValue) }
}
```

### 2. SQLVectorType Protocol

```swift
public protocol SQLVectorType {
    associatedtype Storage: SQLValueRepresentable

    static var elementType: VectorElementType { get }
    static func pack(_ elements: [Storage.Element]) -> Data
    static func unpack(_ data: Data) -> [Storage.Element]
}
```

### 3. Concrete Type Conformances (via Swift Extensions)

**Float** — stores as big-endian Float32 bytes (Swift's Float is Float32):

```swift
extension Float: SQLVectorType {
    public static let elementType = VectorElementType.float32

    public static func pack(_ elements: [Float]) -> Data {
        // 4 bytes per element, big-endian
    }

    public static func unpack(_ data: Data) -> [Float] {
        // Read 4-byte big-endian floats
    }
}
```

**Int8** — stores as raw Int8 bytes:

```swift
extension Int8: SQLVectorType {
    public static let elementType = VectorElementType.int8

    public static func pack(_ elements: [Int8]) -> Data { ... }
    public static func unpack(_ data: Data) -> [Int8] { ... }
}
```

**Bool** — stores `[Bool]` packed into bits for bit vectors:

```swift
extension Bool: SQLVectorType {
    public static let elementType = VectorElementType.bit

    public static func pack(_ elements: [Bool]) -> Data {
        // 8 bools per byte, MSB first
        // e.g., [true, true, false, false, false, false, false, false] -> 0xC0
    }

    public static func unpack(_ data: Data) -> [Bool] {
        // Unpack bits to booleans
    }
}
```

### 4. Vector Struct

```swift
public struct Vector<Value: SQLVectorType>: SQLValueRepresentable, Hashable {
    public let elements: [Value]

    public init(_ elements: [Value]) {
        self.elements = elements
    }

    public var sqliteValue: SQLValue {
        .vector(Value.elementType, Value.pack(elements))
    }

    public init?(sqliteValue: SQLValue) {
        guard case let .vector(elementType, data) = sqliteValue,
              elementType == Value.elementType else {
            return nil
        }
        self.elements = Value.unpack(data)
    }
}
```

### 5. SQLValue Changes

**Remove:**
```swift
case vector([Float])  // OLD: JSON string storage
```

**Add:**
```swift
case vector(VectorElementType, Data)
```

**Updated bind method:**
```swift
case vector(let elementType, let data):
    let byteCount = data.count
    guard byteCount <= Int(Int32.max) else {
        throw SQLiteError.general(...)
    }
    result = sqlite3_bind_blob(statement, index, (data as NSData).bytes, Int32(byteCount), SQLITE_TRANSIENT)
    sqlite3_result_subtype(statement, index, elementType.sqliteSubtype)
```

### 6. Updated Initializer (stmt:col:)

When reading a vector back, the subtype is not automatically available from `sqlite3_column_value`. We rely on explicit `Vector<...>` initialization rather than auto-detection.

## Breaking Changes

- `SQLValue.vector([Float])` is removed
- `Vector` (unparameterized) is removed — use `Vector<Float>`, `Vector<Int8>`, or `Vector<Bool>`
- `Vector<Float>` now uses blob storage (previously JSON string)

## Files Affected

- `Sources/SQLCipher/Core/SQLValue.swift`

## Test Plan

1. Insert `Vector<Float>` and query back, verify byte-for-byte equality
2. Insert `Vector<Int8>` and query back
3. Insert `Vector<Bool>` with `[Bool]` and query back, verify bit packing
4. Verify `vec_distance_cosine` works with inserted blob vectors
5. Verify old `SQLValue.vector` cases are handled (compile error for removed case)
