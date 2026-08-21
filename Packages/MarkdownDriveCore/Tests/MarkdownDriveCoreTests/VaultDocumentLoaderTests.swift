import Foundation
import XCTest

@testable import MarkdownDriveCore

final class VaultDocumentLoaderTests: XCTestCase {
    func testLoadsExactUTF8TextAndRemoteRevisionFromVaultFile() async throws {
        let tree = makeTree()
        let revision = makeRevision()
        let client = FakeDriveContentClient(
            result: .success(
                DriveFileDownload(
                    item: file(id: "note", parentIDs: ["nested"]),
                    data: Data("# 日本語\n\n本文\n".utf8),
                    revision: revision
                )
            )
        )
        let loader = VaultDocumentLoader(driveContentClient: client)

        let document = try await loader.load(fileID: "note", from: tree)

        XCTAssertEqual(document.fileID, "note")
        XCTAssertEqual(document.name, "note.md")
        XCTAssertEqual(document.text, "# 日本語\n\n本文\n")
        XCTAssertEqual(document.remoteRevision, revision)
        XCTAssertFalse(document.isDirty)
    }

    func testUsesVersionMatchedCachedDocumentWithoutDownloadingContents() async throws {
        let revision = makeRevision()
        let cachedDocument = MarkdownDocument(
            fileID: "note",
            name: "note.md",
            text: "cached text",
            remoteRevision: revision
        )
        let cache = FakeMarkdownDocumentReadCache(documents: [cachedDocument])
        let client = FakeDriveContentClient(
            result: .failure(.networkFailure),
            metadataResults: [
                "note": .success(
                    DriveFileMetadata(
                        item: file(id: "note", parentIDs: ["nested"]),
                        revision: revision
                    )
                )
            ]
        )
        let loader = VaultDocumentLoader(
            driveContentClient: client,
            documentReadCache: cache
        )

        let document = try await loader.load(
            fileID: "note",
            from: makeTree(),
            cacheScope: makeCacheScope()
        )

        XCTAssertEqual(document, cachedDocument)
        let requestedIDs = await client.requestedIDs()
        XCTAssertEqual(requestedIDs, [])
    }

    func testStaleCachedDocumentIsReplacedFromDrive() async throws {
        let cachedDocument = MarkdownDocument(
            fileID: "note",
            name: "note.md",
            text: "stale text",
            remoteRevision: makeRevision()
        )
        let currentRevision = DriveFileRevision(
            version: "2",
            modifiedTime: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let cache = FakeMarkdownDocumentReadCache(documents: [cachedDocument])
        let client = FakeDriveContentClient(
            result: .success(
                DriveFileDownload(
                    item: file(id: "note", parentIDs: ["nested"]),
                    data: Data("current text".utf8),
                    revision: currentRevision
                )
            )
        )
        let loader = VaultDocumentLoader(
            driveContentClient: client,
            documentReadCache: cache
        )

        let document = try await loader.load(
            fileID: "note",
            from: makeTree(),
            cacheScope: makeCacheScope()
        )

        XCTAssertEqual(document.text, "current text")
        XCTAssertEqual(document.remoteRevision, currentRevision)
        let cachedReplacement = try await cache.loadDocument(
            fileID: "note",
            scope: makeCacheScope()
        )
        XCTAssertEqual(cachedReplacement, document)
    }

    func testCacheFailureDoesNotPreventDriveLoad() async throws {
        let cache = FakeMarkdownDocumentReadCache(loadError: .networkFailure)
        let client = FakeDriveContentClient(
            result: .success(
                DriveFileDownload(
                    item: file(id: "note", parentIDs: ["nested"]),
                    data: Data("remote text".utf8),
                    revision: makeRevision()
                )
            )
        )
        let loader = VaultDocumentLoader(
            driveContentClient: client,
            documentReadCache: cache
        )

        let document = try await loader.load(
            fileID: "note",
            from: makeTree(),
            cacheScope: makeCacheScope()
        )

        XCTAssertEqual(document.text, "remote text")
    }

    func testDocumentTracksDirtyStateAgainstLastSavedText() {
        let revision = makeRevision()
        var document = MarkdownDocument(
            fileID: "note",
            name: "note.md",
            text: "original",
            remoteRevision: revision
        )

        document.updateText("edited")
        XCTAssertTrue(document.isDirty)

        document.updateText("original")
        XCTAssertFalse(document.isDirty)

        document.updateText("saved edit")
        document.markSaved(revision: DriveFileRevision(version: "2", modifiedTime: Date()))
        XCTAssertFalse(document.isDirty)
    }

    func testDocumentCanRecordSavedSnapshotWhileNewerEditsRemainDirty() {
        let initialRevision = makeRevision()
        var document = MarkdownDocument(
            fileID: "note",
            name: "note.md",
            text: "original",
            remoteRevision: initialRevision
        )
        document.updateText("text sent to Drive")
        document.updateText("newer local edits")
        let savedRevision = DriveFileRevision(version: "2", modifiedTime: Date())

        document.recordSavedText("text sent to Drive", revision: savedRevision)

        XCTAssertEqual(document.text, "newer local edits")
        XCTAssertEqual(document.remoteRevision, savedRevision)
        XCTAssertTrue(document.isDirty)
    }

    func testDocumentRenameAdvancesRevisionWithoutDiscardingDirtyText() {
        var document = MarkdownDocument(
            fileID: "note",
            name: "note.md",
            text: "original",
            remoteRevision: makeRevision()
        )
        document.updateText("unsaved local text")
        let renamedRevision = DriveFileRevision(version: "2", modifiedTime: Date())

        document.recordRename(name: "Renamed.md", revision: renamedRevision)

        XCTAssertEqual(document.name, "Renamed.md")
        XCTAssertEqual(document.text, "unsaved local text")
        XCTAssertEqual(document.remoteRevision, renamedRevision)
        XCTAssertTrue(document.isDirty)
    }

    func testRejectsArbitraryFileIDBeforeDownloading() async {
        let client = FakeDriveContentClient(result: .failure(.itemNotFound))
        let loader = VaultDocumentLoader(driveContentClient: client)

        do {
            _ = try await loader.load(fileID: "outside", from: makeTree())
            XCTFail("Expected Vault boundary violation")
        } catch {
            XCTAssertEqual(error as? DriveError, .vaultBoundaryViolation)
        }

        let requestedIDs = await client.requestedIDs()
        XCTAssertEqual(requestedIDs, [])
    }

    func testRejectsFileMovedOutsideVaultAfterTreeWasLoaded() async {
        let client = FakeDriveContentClient(
            result: .success(
                DriveFileDownload(
                    item: file(id: "note", parentIDs: ["outside-folder"]),
                    data: Data("text".utf8),
                    revision: makeRevision()
                )
            )
        )
        let loader = VaultDocumentLoader(driveContentClient: client)

        do {
            _ = try await loader.load(fileID: "note", from: makeTree())
            XCTFail("Expected Vault boundary violation")
        } catch {
            XCTAssertEqual(error as? DriveError, .vaultBoundaryViolation)
        }
    }

    func testRejectsCurrentFileOutsideVaultBeforeDownloading() async {
        let client = FakeDriveContentClient(
            result: .failure(.itemNotFound),
            itemResults: [
                "note": .success(file(id: "note", parentIDs: ["outside-folder"]))
            ]
        )
        let loader = VaultDocumentLoader(driveContentClient: client)

        do {
            _ = try await loader.load(fileID: "note", from: makeTree())
            XCTFail("Expected Vault boundary violation")
        } catch {
            XCTAssertEqual(error as? DriveError, .vaultBoundaryViolation)
        }

        let requestedIDs = await client.requestedIDs()
        XCTAssertEqual(requestedIDs, [])
    }

    func testRejectsFileWhoseAncestorMovedOutsideVaultAfterTreeWasLoaded() async {
        let movedFolder = DriveItem(
            id: "nested",
            name: "nested",
            kind: .folder,
            parentIDs: ["outside-folder"]
        )
        let client = FakeDriveContentClient(
            result: .success(
                DriveFileDownload(
                    item: file(id: "note", parentIDs: ["nested"]),
                    data: Data("remote text".utf8),
                    revision: makeRevision()
                )
            ),
            itemResults: ["nested": .success(movedFolder)]
        )
        let loader = VaultDocumentLoader(driveContentClient: client)

        do {
            _ = try await loader.load(fileID: "note", from: makeTree())
            XCTFail("Expected moved ancestor to violate the Vault boundary")
        } catch {
            XCTAssertEqual(error as? DriveError, .vaultBoundaryViolation)
        }
    }

    func testRejectsInvalidUTF8WithoutAlteringBytes() async {
        let client = FakeDriveContentClient(
            result: .success(
                DriveFileDownload(
                    item: file(id: "note", parentIDs: ["nested"]),
                    data: Data([0xC3, 0x28]),
                    revision: makeRevision()
                )
            )
        )
        let loader = VaultDocumentLoader(driveContentClient: client)

        do {
            _ = try await loader.load(fileID: "note", from: makeTree())
            XCTFail("Expected invalid UTF-8")
        } catch {
            XCTAssertEqual(error as? DriveError, .invalidUTF8)
        }
    }

    private func makeTree() -> VaultTree {
        VaultTree(
            root: DriveTreeNode(
                item: folder(id: "vault"),
                children: [
                    DriveTreeNode(
                        item: folder(id: "nested"),
                        children: [DriveTreeNode(item: file(id: "note", parentIDs: ["nested"]))]
                    )
                ]
            )
        )
    }

    private func folder(id: String) -> DriveItem {
        DriveItem(id: id, name: id, kind: .folder)
    }

    private func file(id: String, parentIDs: [String]) -> DriveItem {
        DriveItem(
            id: id,
            name: "note.md",
            kind: .file,
            mimeType: "text/markdown",
            parentIDs: parentIDs
        )
    }

    private func makeRevision() -> DriveFileRevision {
        DriveFileRevision(
            version: "1",
            modifiedTime: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeCacheScope() -> DriveChangeCursorScope {
        DriveChangeCursorScope(
            accountID: DriveAccountID(rawValue: "account"),
            vaultRootFolderID: "vault"
        )
    }
}

private actor FakeDriveContentClient: DriveContentClient {
    private let result: Result<DriveFileDownload, DriveError>
    private let itemResults: [String: Result<DriveItem, DriveError>]
    private let metadataResults: [String: Result<DriveFileMetadata, DriveError>]
    private var requestedFileIDs: [String] = []

    init(
        result: Result<DriveFileDownload, DriveError>,
        itemResults: [String: Result<DriveItem, DriveError>]? = nil,
        metadataResults: [String: Result<DriveFileMetadata, DriveError>]? = nil
    ) {
        self.result = result
        var resolvedItemResults: [String: Result<DriveItem, DriveError>] = [
            "note": .success(
                DriveItem(
                    id: "note",
                    name: "note.md",
                    kind: .file,
                    mimeType: "text/markdown",
                    parentIDs: ["nested"]
                )
            ),
            "nested": .success(
                DriveItem(
                    id: "nested",
                    name: "nested",
                    kind: .folder,
                    parentIDs: ["vault"]
                )
            ),
        ]
        resolvedItemResults.merge(itemResults ?? [:]) { _, replacement in replacement }
        self.itemResults = resolvedItemResults
        let revision: DriveFileRevision
        switch result {
        case .success(let download):
            revision = download.revision
        case .failure:
            revision = DriveFileRevision(
                version: "1",
                modifiedTime: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
        let noteItem =
            (try? resolvedItemResults["note"]?.get())
            ?? DriveItem(
                id: "note",
                name: "note.md",
                kind: .file,
                mimeType: "text/markdown",
                parentIDs: ["nested"]
            )
        var resolvedMetadataResults: [String: Result<DriveFileMetadata, DriveError>] = [
            "note": .success(DriveFileMetadata(item: noteItem, revision: revision))
        ]
        resolvedMetadataResults.merge(metadataResults ?? [:]) { _, replacement in replacement }
        self.metadataResults = resolvedMetadataResults
    }

    func getItem(id: String) async throws -> DriveItem {
        try itemResults[id, default: .failure(.itemNotFound)].get()
    }

    func getReadableFileMetadata(id: String) async throws -> DriveFileMetadata {
        try metadataResults[id, default: .failure(.itemNotFound)].get()
    }

    func downloadFile(id: String) async throws -> DriveFileDownload {
        requestedFileIDs.append(id)
        return try result.get()
    }

    func requestedIDs() -> [String] {
        requestedFileIDs
    }
}

private actor FakeMarkdownDocumentReadCache: MarkdownDocumentReadCache {
    private var documents: [String: MarkdownDocument]
    private let loadError: DriveError?

    init(
        documents: [MarkdownDocument] = [],
        loadError: DriveError? = nil
    ) {
        self.documents = Dictionary(uniqueKeysWithValues: documents.map { ($0.fileID, $0) })
        self.loadError = loadError
    }

    func loadDocument(
        fileID: String,
        scope: DriveChangeCursorScope
    ) throws -> MarkdownDocument? {
        if let loadError {
            throw loadError
        }
        return documents[fileID]
    }

    func saveDocument(
        _ document: MarkdownDocument,
        scope: DriveChangeCursorScope
    ) {
        documents[document.fileID] = document
    }
}
