import Foundation
import MarkdownDriveCore
import XCTest

@testable import MarkdownDriveMac

final class FileMarkdownDocumentReadCacheTests: XCTestCase {
    func testPersistsDocumentsSeparatelyByAccountAndVault() async throws {
        let fileURL = try makeCacheFileURL()
        let firstScope = scope(accountID: "first-account", vaultID: "vault")
        let secondScope = scope(accountID: "second-account", vaultID: "vault")
        let cache = FileMarkdownDocumentReadCache(fileURL: fileURL)
        try await cache.saveDocument(document(text: "first"), scope: firstScope)
        try await cache.saveDocument(document(text: "second"), scope: secondScope)

        let restoredCache = FileMarkdownDocumentReadCache(fileURL: fileURL)
        let first = try await restoredCache.loadDocument(fileID: "note", scope: firstScope)
        let second = try await restoredCache.loadDocument(fileID: "note", scope: secondScope)

        XCTAssertEqual(first?.text, "first")
        XCTAssertEqual(second?.text, "second")
    }

    func testEvictsLeastRecentlyUsedDocument() async throws {
        let cache = FileMarkdownDocumentReadCache(
            fileURL: try makeCacheFileURL(),
            maximumEntryCount: 2
        )
        let cacheScope = scope(accountID: "account", vaultID: "vault")
        try await cache.saveDocument(document(fileID: "first"), scope: cacheScope)
        try await Task.sleep(nanoseconds: 1_000_000)
        try await cache.saveDocument(document(fileID: "second"), scope: cacheScope)
        try await Task.sleep(nanoseconds: 1_000_000)
        _ = try await cache.loadDocument(fileID: "first", scope: cacheScope)
        try await Task.sleep(nanoseconds: 1_000_000)
        try await cache.saveDocument(document(fileID: "third"), scope: cacheScope)

        let first = try await cache.loadDocument(fileID: "first", scope: cacheScope)
        let second = try await cache.loadDocument(fileID: "second", scope: cacheScope)
        let third = try await cache.loadDocument(fileID: "third", scope: cacheScope)

        XCTAssertNotNil(first)
        XCTAssertNil(second)
        XCTAssertNotNil(third)
    }

    func testCorruptSnapshotIsDiscardedAndCanBeRebuilt() async throws {
        let fileURL = try makeCacheFileURL()
        try Data("not json".utf8).write(to: fileURL)
        let cacheScope = scope(accountID: "account", vaultID: "vault")
        let cache = FileMarkdownDocumentReadCache(fileURL: fileURL)

        let missing = try await cache.loadDocument(fileID: "note", scope: cacheScope)
        XCTAssertNil(missing)

        try await cache.saveDocument(document(text: "rebuilt"), scope: cacheScope)
        let restoredCache = FileMarkdownDocumentReadCache(fileURL: fileURL)
        let rebuilt = try await restoredCache.loadDocument(fileID: "note", scope: cacheScope)
        XCTAssertEqual(rebuilt?.text, "rebuilt")
    }

    func testDirtyDocumentIsNeverCached() async throws {
        let cache = FileMarkdownDocumentReadCache(fileURL: try makeCacheFileURL())
        let cacheScope = scope(accountID: "account", vaultID: "vault")
        var dirtyDocument = document(text: "original")
        dirtyDocument.updateText("unsaved")

        try await cache.saveDocument(dirtyDocument, scope: cacheScope)

        let loaded = try await cache.loadDocument(fileID: "note", scope: cacheScope)
        XCTAssertNil(loaded)
    }

    private func makeCacheFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("cache.json", isDirectory: false)
    }

    private func scope(accountID: String, vaultID: String) -> DriveChangeCursorScope {
        DriveChangeCursorScope(
            accountID: DriveAccountID(rawValue: accountID),
            vaultRootFolderID: vaultID
        )
    }

    private func document(
        fileID: String = "note",
        text: String = "text"
    ) -> MarkdownDocument {
        MarkdownDocument(
            fileID: fileID,
            name: "\(fileID).md",
            text: text,
            remoteRevision: DriveFileRevision(
                version: "1",
                modifiedTime: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }
}
