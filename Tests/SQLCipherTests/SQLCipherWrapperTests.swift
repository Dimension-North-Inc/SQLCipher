//
//  SQLCipherWrapperTests.swift
//  SQLCipherTests
//
//  Created by Kimi on 4/23/26.
//  Copyright © 2026 Dimension North Inc. All rights reserved.
//

import Testing
import Foundation
@testable import SQLCipher

@Suite struct SQLCipherWrapperTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func testTemporaryLocationCreatesDatabase() throws {
        let content = FileWrapper(regularFileWithContents: Data())
        let wrapper = try SQLCipherWrapper(location: .temporary, content: content)

        #expect(FileManager.default.fileExists(atPath: wrapper.url.path))
        #expect(wrapper.db.path == wrapper.url.path)
    }

    @Test func testTemporaryLocationIsRemovedOnDeinit() async throws {
        let content = FileWrapper(regularFileWithContents: Data())
        var wrapper: SQLCipherWrapper? = try SQLCipherWrapper(location: .temporary, content: content)
        let url = wrapper!.url

        wrapper = nil

        // Give deinit a moment to fire
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func testFixedLocationCreatesDatabase() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("db.sqlite")
        let content = FileWrapper(regularFileWithContents: Data())

        let wrapper = try SQLCipherWrapper(location: .fixed(url), content: content)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(wrapper.db.path == url.path)
    }

    @Test func testFixedLocationOpensExistingDatabase() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("db.sqlite")
        let content = FileWrapper(regularFileWithContents: Data())

        let wrapper1 = try SQLCipherWrapper(location: .fixed(url), content: content)
        try wrapper1.db.writer.exec("CREATE TABLE test (id INTEGER PRIMARY KEY)")

        let wrapper2 = try SQLCipherWrapper(location: .fixed(url), content: content)
        let result = try wrapper2.db.reader.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='test'")
        #expect(result.count == 1)
    }

    @Test func testFixedLocationReinstall() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("db.sqlite")
        let content = FileWrapper(regularFileWithContents: Data())

        let wrapper1 = try SQLCipherWrapper(location: .fixed(url), content: content)
        try wrapper1.db.writer.exec("CREATE TABLE old_table (id INTEGER PRIMARY KEY)")

        let wrapper2 = try SQLCipherWrapper(location: .fixed(url, reinstall: true), content: content)
        let result = try wrapper2.db.reader.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='old_table'")
        #expect(result.count == 0)
    }

    @Test func testPackageLocation() throws {
        let dir = tempDir()
        let packageURL = dir.appendingPathComponent("MyDB.package")
        let dbContent = FileWrapper(regularFileWithContents: Data())
        let packageContent = FileWrapper(directoryWithFileWrappers: ["db.sqlite": dbContent])

        let wrapper = try SQLCipherWrapper(location: .fixed(packageURL), content: packageContent)

        #expect(FileManager.default.fileExists(atPath: packageURL.path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("db.sqlite").path))
        #expect(wrapper.db.path == packageURL.appendingPathComponent("db.sqlite").path)
    }

    @Test func testWrapperCheckpointAndFileWrapper() throws {
        let content = FileWrapper(regularFileWithContents: Data())
        let wrapper = try SQLCipherWrapper(location: .temporary, content: content)

        try wrapper.db.writer.exec("CREATE TABLE test (id INTEGER PRIMARY KEY)")
        try wrapper.db.writer.exec("INSERT INTO test (id) VALUES (42)")

        let fileWrapper = try wrapper.wrapper
        #expect(fileWrapper.isRegularFile || fileWrapper.isDirectory)
    }

    @Test func testEncryptedWrapper() throws {
        let content = FileWrapper(regularFileWithContents: Data())
        let wrapper = try SQLCipherWrapper(location: .temporary, content: content, key: "secret-key")

        #expect(wrapper.db.isEncrypted == true)

        try wrapper.db.writer.exec("CREATE TABLE secrets (id INTEGER PRIMARY KEY)")

        // Opening without key should fail
        #expect(throws: SQLiteError.self) {
            let _ = try SQLCipher(path: wrapper.db.path, key: "wrong-key")
        }
    }
}
