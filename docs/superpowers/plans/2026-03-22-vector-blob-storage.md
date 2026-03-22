# Vector Blob Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `SQLValue.vector([Float])` with `SQLValue.vector(VectorElementType, Data)` and parameterized `Vector<Value: SQLVectorType>` types that store vectors as blobs.

**Architecture:** Add a `VectorElementType` enum matching sqlite-vec subtypes, a `SQLVectorType` protocol for packing/unpacking, and conform existing Swift types (`Float`, `Int8`, `Bool`) to the protocol. Update `Vector` to be parameterized over the element type. The `SQLValue.vector` case changes from JSON string storage to blob storage with element type discriminator.

Note: `Float` in Swift IS `Float32` (they're synonymous), so `Vector<Float>` corresponds directly to sqlite-vec's `float` element type.

**Tech Stack:** Swift, CSQLCipher (sqlite-vec extension)

---

## File Structure

All changes are localized to a single file:

- Modify: `Sources/SQLCipher/Core/SQLValue.swift`

Tests will be added to the existing test file:

- Modify: `Tests/SQLCipherTests/SQLCipherTests.swift`

---

## Task 1: Add VectorElementType Enum

**Files:**
- Modify: `Sources/SQLCipher/Core/SQLValue.swift:1-50`

- [ ] **Step 1: Write failing test for VectorElementType**

In `SQLCipherTests.swift`, add a placeholder test that references `VectorElementType.float32` — it should fail to compile until the enum is added.

- [ ] **Step 2: Add VectorElementType enum after the SQLValue enum**

Add before the `extension SQLValue: CustomStringConvertible`:

```swift
/// Element types supported by sqlite-vec for vector storage.
public enum VectorElementType: Int {
    case float32 = 223  // SQLITE_VEC_ELEMENT_TYPE_FLOAT32
    case bit = 224     // SQLITE_VEC_ELEMENT_TYPE_BIT
    case int8 = 225    // SQLITE_VEC_ELEMENT_TYPE_INT8

    /// Returns the SQLite subtype value for this element type.
    public var sqliteSubtype: Int32 { Int32(rawValue) }
}
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/SQLCipher/Core/SQLValue.swift Tests/SQLCipherTests/SQLCipherTests.swift
git commit -m "feat: add VectorElementType enum with sqlite-vec subtypes

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 2: Add SQLVectorType Protocol

**Files:**
- Modify: `Sources/SQLCipher/Core/SQLValue.swift`

- [ ] **Step 1: Write failing test for SQLVectorType**

Add a test that attempts to use `Vector<Float32>` — it should fail until the protocol and struct are added.

- [ ] **Step 2: Add SQLVectorType protocol after VectorElementType**

```swift
/// A type that can be used as the element type for a vector.
/// Conforming types provide packing and unpacking logic for storing
/// vector data as blobs in SQLite.
public protocol SQLVectorType {
    /// The underlying storage type for vector elements.
    associatedtype Storage: SQLValueRepresentable

    /// The sqlite-vec element type for this vector type.
    static var elementType: VectorElementType { get }

    /// Packs an array of elements into Data for blob storage.
    static func pack(_ elements: [Storage.Element]) -> Data

    /// Unpacks Data back into an array of elements.
    static func unpack(_ data: Data) -> [Storage.Element]
}
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/SQLCipher/Core/SQLValue.swift
git commit -m "feat: add SQLVectorType protocol

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 3: Conform Float to SQLVectorType

**Files:**
- Modify: `Sources/SQLCipher/Core/SQLValue.swift`

- [ ] **Step 1: Write failing test for Float pack/unpack**

Add tests verifying Float (Swift's Float32) packing produces 4-byte big-endian floats and unpacking reverses it.

- [ ] **Step 2: Add Float extension with SQLVectorType conformance**

```swift
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
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Run tests**

Run: `swift test --filter Float`
Expected: Tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/SQLCipher/Core/SQLValue.swift Tests/SQLCipherTests/SQLCipherTests.swift
git commit -m "feat: conform Float to SQLVectorType with big-endian packing

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 4: Conform Int8 to SQLVectorType

**Files:**
- Modify: `Sources/SQLCipher/Core/SQLValue.swift`

- [ ] **Step 1: Write failing test for Int8 pack/unpack**

- [ ] **Step 2: Add Int8 extension with SQLVectorType conformance**

```swift
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
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Run tests**

Run: `swift test --filter Int8`
Expected: Tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/SQLCipher/Core/SQLValue.swift Tests/SQLCipherTests/SQLCipherTests.swift
git commit -m "feat: conform Int8 to SQLVectorType

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 5: Conform Bool to SQLVectorType

**Files:**
- Modify: `Sources/SQLCipher/Core/SQLValue.swift`

- [ ] **Step 1: Write failing test for Bool pack/unpack**

Verify: `[true, true, false, false, false, false, false, false]` packs to `Data([0xC0])` and unpacks back.

- [ ] **Step 2: Add Bool extension with SQLVectorType conformance**

```swift
/// Bool extension for sqlite-vec bit vector storage.
/// Stores elements as packed bits (8 bools per byte, MSB first).
extension Bool: SQLVectorType {
    public static let elementType = VectorElementType.bit

    public static func pack(_ elements: [Bool]) -> Data {
        var result = Data()
        for chunk in elements.chunked(into: 8) {
            var byte: UInt8 = 0
            for (index, bool) in chunk.enumerated() {
                if bool {
                    byte |= (1 << (7 - index))
                }
            }
            result.append(byte)
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
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Run tests**

Run: `swift test --filter Bool`
Expected: Tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/SQLCipher/Core/SQLValue.swift Tests/SQLCipherTests/SQLCipherTests.swift
git commit -m "feat: conform Bool to SQLVectorType with bit-packing support

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 6: Update Vector Struct to be Parameterized

**Files:**
- Modify: `Sources/SQLCipher/Core/SQLValue.swift` (replace existing Vector struct ~line 370-398)

- [ ] **Step 1: Write failing test for parameterized Vector**

Test that `Vector<Float>([1.0, 2.0]).sqliteValue` produces a `.vector` case with `.float32` element type and correct blob data.

- [ ] **Step 2: Replace Vector struct**

Replace the existing `Vector` struct (around line 370) with the parameterized version:

```swift
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
```

Note: `Vector<Float>` is used for float32 vectors, `Vector<Int8>` for int8, and `Vector<Bool>` for bit vectors. The old non-parameterized `Vector` is removed.

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Run tests**

Run: `swift test --filter Vector`
Expected: Tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/SQLCipher/Core/SQLValue.swift Tests/SQLCipherTests/SQLCipherTests.swift
git commit -m "refactor: make Vector generic over SQLVectorType

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 7: Update Existing Tests Using Old Vector Type

**Files:**
- Modify: `Tests/SQLCipherTests/SQLCipherTests.swift`

- [ ] **Step 1: Find and update existing Vector usages**

Search for `Vector` type usages in tests. The existing tests at lines 363-395 use the non-parameterized `Vector`:

```swift
struct EmbeddingParams {
    var id: Int
    var vector: Vector  // OLD - change to Vector<Float>
}
let embedding = Vector([1.0, 0.0, 0.0])  // OLD - change to Vector<Float>([1.0, 0.0, 0.0])
```

Update these to use `Vector<Float>` instead of `Vector`.

- [ ] **Step 2: Run tests to verify**

Run: `swift test`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add Tests/SQLCipherTests/SQLCipherTests.swift
git commit -m "refactor: update existing tests to use Vector<Float>

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 8: Update SQLValue Enum and Bind Method

**Files:**
- Modify: `Sources/SQLCipher/Core/SQLValue.swift`

- [ ] **Step 1: Remove old vector case and add new one**

Remove from `SQLValue` enum (~line 43-47):
```swift
case vector([Float])
```

Add new case (~line 24, after `.blob(Data)`):
```swift
case vector(VectorElementType, Data)
```

- [ ] **Step 2: Update description property**

Change:
```swift
case .vector(let values):
    return values.description
```
To:
```swift
case .vector(let elementType, let data):
    return "vector(\(elementType), \(data.count) bytes)"
```

- [ ] **Step 3: Update Encodable conformance**

Change:
```swift
case .vector(let values):
    try container.encode(values)
```
To:
```swift
case .vector(let elementType, let data):
    try container.encode(elementType)
    try container.encode(data)
```

- [ ] **Step 4: Update bind(to:at:on:) method**

Remove old case (~line 169-176):
```swift
case .vector(let values):
    let doubles = values.map { Double($0) }
    guard let jsonData = try? JSONSerialization.data(withJSONObject: doubles),
          let jsonString = String(data: jsonData, encoding: .utf8) else {
        throw SQLiteError.general(code: SQLITE_ERROR, message: "\(#function) unable to convert vector to JSON string")
    }
    result = sqlite3_bind_text(statement, index, jsonString, -1, SQLITE_TRANSIENT)
```

Add new case after the `blob` case:
```swift
case .vector(let elementType, let data):
    let byteCount = data.count
    guard byteCount <= Int(Int32.max) else {
        throw SQLiteError.general(
            code: SQLITE_TOOBIG,
            message: "Blob size (\(byteCount) bytes) exceeds SQLite's 2GB limit"
        )
    }
    result = sqlite3_bind_blob(statement, index, (data as NSData).bytes, Int32(byteCount), SQLITE_TRANSIENT)
    sqlite3_result_subtype(statement, index, elementType.sqliteSubtype)
```

- [ ] **Step 5: Verify build**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Run tests**

Run: `swift test`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add Sources/SQLCipher/Core/SQLValue.swift
git commit -m "refactor: replace SQLValue.vector([Float]) with vector(VectorElementType, Data)

BREAKING CHANGE: SQLValue.vector case now takes (VectorElementType, Data)
instead of ([Float]). Use Vector<Float>, Vector<Int8>, or Vector<Bool>
instead of the old Vector type.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 9: Add Vector Integration Tests

**Files:**
- Modify: `Tests/SQLCipherTests/SQLCipherTests.swift`

- [ ] **Step 1: Add tests for Vector<Float> with vec0 table**

Add an integration test that:
1. Creates a vec0 virtual table with `float[3]`
2. Inserts a `Vector<Float>` using parameterized query
3. Verifies vec_distance_cosine works

```swift
func testVectorFloatRoundTrip() throws {
    let db = try SQLCipher(path: ":memory:")
    try db.writer.exec("CREATE VIRTUAL TABLE vectors USING vec0(v float[3]);")

    struct Params {
        var v: Vector<Float>
    }
    let insert: SQLQuery<Params> = "INSERT INTO vectors (v) VALUES (\(\.v))"
    try db.writer.execute(insert, Params(v: Vector<Float>([1.0, 2.0, 3.0])))

    // Verify with distance function
    let search: SQLStaticQuery = """
        SELECT vec_distance_cosine(v, vector_from_values(1.0, 2.0, 3.0)) as dist FROM vectors
    """
    let result = try db.reader.execute(search)
    if let dist: Double = result.first?["dist"] {
        XCTAssertEqual(dist, 0.0, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Add tests for Vector<Int8>**

Similar test for int8 element type.

- [ ] **Step 3: Add tests for Vector<Bool> (bit vector)**

Verify bit packing: insert `[true, true, false, false]` and query back.

- [ ] **Step 4: Run all tests**

Run: `swift test`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Tests/SQLCipherTests/SQLCipherTests.swift
git commit -m "test: add vector integration tests for Float, Int8, and Bool types

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Summary

After completing all tasks:
- `SQLValue.vector([Float])` is removed
- `SQLValue.vector(VectorElementType, Data)` stores vectors as blobs with subtype
- `Vector<Float>`, `Vector<Int8>`, `Vector<Bool>` provide type-safe vector access
- `Float`, `Int8`, and `Bool` conform to `SQLVectorType` for packing/unpacking
- All sqlite-vec element types are supported (float32, int8, bit)
- vec_distance_cosine and other vector functions work with inserted data
