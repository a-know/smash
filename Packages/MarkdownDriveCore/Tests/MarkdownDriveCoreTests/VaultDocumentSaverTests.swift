import Foundation
import XCTest

@testable import MarkdownDriveCore

final class VaultDocumentSaverTests: XCTestCase {
    func testSavesUTF8ToSameFileAndMarksReturnedDocumentClean() async throws {
        let openedRevision = revision("1")
        let savedRevision = revision("2")
        let client = FakeDriveWriteClient(
            metadataResult: .success(metadata(revision: openedRevision)),
            updateResult: .success(metadata(revision: savedRevision))
        )
        let saver = VaultDocumentSaver(driveWriteClient: client)
        var document = makeDocument(revision: openedRevision)
        document.updateText("# 更新\n")

        let saved = try await saver.save(document: document, in: makeTree())

        XCTAssertEqual(saved.fileID, "note")
        XCTAssertEqual(saved.text, "# 更新\n")
        XCTAssertEqual(saved.remoteRevision, savedRevision)
        XCTAssertFalse(saved.isDirty)
        let updates = await client.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].id, "note")
        XCTAssertEqual(updates[0].data, Data("# 更新\n".utf8))
        XCTAssertEqual(updates[0].mimeType, "text/markdown; charset=utf-8")
    }

    func testConflictNeverSendsUpdateAndOriginalDocumentStaysDirty() async {
        let client = FakeDriveWriteClient(
            metadataResult: .success(metadata(revision: revision("2"))),
            updateResult: .failure(.networkFailure)
        )
        let saver = VaultDocumentSaver(driveWriteClient: client)
        var document = makeDocument(revision: revision("1"))
        document.updateText("local edits")

        do {
            _ = try await saver.save(document: document, in: makeTree())
            XCTFail("Expected conflict")
        } catch {
            XCTAssertEqual(
                error as? DocumentSaveError,
                .conflict(remoteRevision: revision("2"))
            )
        }

        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.text, "local edits")
        let updateCount = await client.updateCount()
        XCTAssertEqual(updateCount, 0)
    }

    func testDeletedRemoteFileRetainsDirtyText() async {
        let client = FakeDriveWriteClient(
            metadataResult: .failure(.itemNotFound),
            updateResult: .failure(.itemNotFound)
        )
        let saver = VaultDocumentSaver(driveWriteClient: client)
        var document = makeDocument(revision: revision("1"))
        document.updateText("recover me")

        do {
            _ = try await saver.save(document: document, in: makeTree())
            XCTFail("Expected remote deletion")
        } catch {
            XCTAssertEqual(error as? DocumentSaveError, .remoteDeleted)
        }

        XCTAssertEqual(document.text, "recover me")
        XCTAssertTrue(document.isDirty)
        let updateCount = await client.updateCount()
        XCTAssertEqual(updateCount, 0)
    }

    func testNetworkFailureDuringUpdateIsAmbiguousAndIsNotRetried() async {
        let openedRevision = revision("1")
        let client = FakeDriveWriteClient(
            metadataResult: .success(metadata(revision: openedRevision)),
            updateResult: .failure(.networkFailure)
        )
        let saver = VaultDocumentSaver(driveWriteClient: client)
        var document = makeDocument(revision: openedRevision)
        document.updateText("retain me")

        do {
            _ = try await saver.save(document: document, in: makeTree())
            XCTFail("Expected ambiguous update status")
        } catch {
            XCTAssertEqual(error as? DocumentSaveError, .updateStatusUnknown)
        }

        XCTAssertEqual(document.text, "retain me")
        XCTAssertTrue(document.isDirty)
        let updateCount = await client.updateCount()
        XCTAssertEqual(updateCount, 1)
    }

    func testMovedFileIsRejectedBeforeUpdate() async {
        let openedRevision = revision("1")
        let client = FakeDriveWriteClient(
            metadataResult: .success(
                metadata(revision: openedRevision, parentIDs: ["outside"])
            ),
            updateResult: .failure(.networkFailure)
        )
        let saver = VaultDocumentSaver(driveWriteClient: client)
        var document = makeDocument(revision: openedRevision)
        document.updateText("local")

        do {
            _ = try await saver.save(document: document, in: makeTree())
            XCTFail("Expected boundary violation")
        } catch {
            XCTAssertEqual(error as? DocumentSaveError, .vaultBoundaryViolation)
        }

        let updateCount = await client.updateCount()
        XCTAssertEqual(updateCount, 0)
    }

    func testCleanDocumentDoesNotAccessDrive() async throws {
        let client = FakeDriveWriteClient(
            metadataResult: .failure(.networkFailure),
            updateResult: .failure(.networkFailure)
        )
        let saver = VaultDocumentSaver(driveWriteClient: client)
        let document = makeDocument(revision: revision("1"))

        let result = try await saver.save(document: document, in: makeTree())

        XCTAssertEqual(result, document)
        let metadataRequestCount = await client.metadataRequestCount()
        let updateCount = await client.updateCount()
        XCTAssertEqual(metadataRequestCount, 0)
        XCTAssertEqual(updateCount, 0)
    }

    private func makeDocument(revision: DriveFileRevision) -> MarkdownDocument {
        MarkdownDocument(
            fileID: "note",
            name: "note.md",
            text: "original",
            remoteRevision: revision
        )
    }

    private func makeTree() -> VaultTree {
        VaultTree(
            root: DriveTreeNode(
                item: DriveItem(id: "vault", name: "Vault", kind: .folder),
                children: [
                    DriveTreeNode(
                        item: DriveItem(
                            id: "note",
                            name: "note.md",
                            kind: .file,
                            parentIDs: ["vault"]
                        )
                    )
                ]
            )
        )
    }

    private func metadata(
        revision: DriveFileRevision,
        parentIDs: [String] = ["vault"]
    ) -> DriveFileMetadata {
        DriveFileMetadata(
            item: DriveItem(
                id: "note",
                name: "note.md",
                kind: .file,
                parentIDs: parentIDs
            ),
            revision: revision
        )
    }

    private func revision(_ version: String) -> DriveFileRevision {
        DriveFileRevision(
            version: version,
            modifiedTime: Date(timeIntervalSince1970: Double(version) ?? 0)
        )
    }
}

private actor FakeDriveWriteClient: DriveWriteClient {
    struct Update: Equatable, Sendable {
        let id: String
        let data: Data
        let mimeType: String
    }

    private let metadataResult: Result<DriveFileMetadata, DriveError>
    private let updateResult: Result<DriveFileMetadata, DriveError>
    private var metadataRequests = 0
    private(set) var updates: [Update] = []

    init(
        metadataResult: Result<DriveFileMetadata, DriveError>,
        updateResult: Result<DriveFileMetadata, DriveError>
    ) {
        self.metadataResult = metadataResult
        self.updateResult = updateResult
    }

    func getFileMetadata(id: String) async throws -> DriveFileMetadata {
        metadataRequests += 1
        return try metadataResult.get()
    }

    func updateFileContent(
        id: String,
        data: Data,
        mimeType: String
    ) async throws -> DriveFileMetadata {
        updates.append(Update(id: id, data: data, mimeType: mimeType))
        return try updateResult.get()
    }

    func metadataRequestCount() -> Int {
        metadataRequests
    }

    func updateCount() -> Int {
        updates.count
    }
}
