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
}

private actor FakeDriveContentClient: DriveContentClient {
    private let result: Result<DriveFileDownload, DriveError>
    private var requestedFileIDs: [String] = []

    init(result: Result<DriveFileDownload, DriveError>) {
        self.result = result
    }

    func downloadFile(id: String) async throws -> DriveFileDownload {
        requestedFileIDs.append(id)
        return try result.get()
    }

    func requestedIDs() -> [String] {
        requestedFileIDs
    }
}
