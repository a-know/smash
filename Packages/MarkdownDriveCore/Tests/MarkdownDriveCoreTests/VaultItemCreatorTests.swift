import Foundation
import XCTest

@testable import MarkdownDriveCore

final class VaultItemCreatorTests: XCTestCase {
    func testCreatesEmptyMarkdownFileAndAddsExtension() async throws {
        let client = FakeItemCreationClient()
        let creator = VaultItemCreator(driveClient: client)

        let metadata = try await creator.createMarkdownFile(
            name: " 日本語メモ ",
            parentFolderID: "vault",
            in: makeTree()
        )

        XCTAssertEqual(metadata.item.name, "日本語メモ.md")
        let creations = await client.fileCreations
        XCTAssertEqual(creations.count, 1)
        XCTAssertEqual(creations[0].name, "日本語メモ.md")
        XCTAssertEqual(creations[0].parentID, "vault")
        XCTAssertEqual(creations[0].data, Data())
        XCTAssertEqual(creations[0].mimeType, "text/markdown; charset=utf-8")
    }

    func testPreservesExistingMarkdownExtensionCaseInsensitively() throws {
        XCTAssertEqual(
            try VaultItemNameRules.markdownFileName(from: "README.MD"),
            "README.MD"
        )
    }

    func testRejectsInvalidNamesBeforeAccessingDrive() async {
        let client = FakeItemCreationClient()
        let creator = VaultItemCreator(driveClient: client)

        for name in ["", "   ", ".", "..", "nested/name", "line\nfeed"] {
            do {
                _ = try await creator.createFolder(
                    name: name,
                    parentFolderID: "vault",
                    in: makeTree()
                )
                XCTFail("Expected invalid name: \(name)")
            } catch {
                XCTAssertEqual(error as? DriveError, .invalidName)
            }
        }

        let folderCreationCount = await client.folderCreations.count
        XCTAssertEqual(folderCreationCount, 0)
    }

    func testCreatesFolderInNestedCurrentVaultFolder() async throws {
        let client = FakeItemCreationClient(
            items: [
                "nested": DriveItem(
                    id: "nested",
                    name: "Nested",
                    kind: .folder,
                    parentIDs: ["vault"]
                )
            ]
        )
        let creator = VaultItemCreator(driveClient: client)

        let folder = try await creator.createFolder(
            name: "Drafts",
            parentFolderID: "nested",
            in: makeTree()
        )

        XCTAssertEqual(folder.name, "Drafts")
        let creations = await client.folderCreations
        XCTAssertEqual(creations.map(\.parentID), ["nested"])
    }

    func testRejectsDestinationThatWasMovedOutsideVault() async {
        let client = FakeItemCreationClient(
            items: [
                "nested": DriveItem(
                    id: "nested",
                    name: "Nested",
                    kind: .folder,
                    parentIDs: ["outside"]
                )
            ]
        )
        let creator = VaultItemCreator(driveClient: client)

        do {
            _ = try await creator.createMarkdownFile(
                name: "note",
                parentFolderID: "nested",
                in: makeTree()
            )
            XCTFail("Expected moved destination to be rejected")
        } catch {
            XCTAssertEqual(error as? DriveError, .vaultBoundaryViolation)
        }

        let fileCreationCount = await client.fileCreations.count
        XCTAssertEqual(fileCreationCount, 0)
    }

    func testRejectsDestinationAbsentFromLoadedTree() async {
        let client = FakeItemCreationClient()
        let creator = VaultItemCreator(driveClient: client)

        do {
            _ = try await creator.createFolder(
                name: "Drafts",
                parentFolderID: "outside",
                in: makeTree()
            )
            XCTFail("Expected arbitrary destination to be rejected")
        } catch {
            XCTAssertEqual(error as? DriveError, .vaultBoundaryViolation)
        }
    }

    func testTrashesCreatedItemWhenDestinationMovesOutsideDuringCreation() async {
        let insideFolder = DriveItem(
            id: "nested",
            name: "Nested",
            kind: .folder,
            parentIDs: ["vault"]
        )
        let outsideFolder = DriveItem(
            id: "nested",
            name: "Nested",
            kind: .folder,
            parentIDs: ["outside"]
        )
        let client = FakeItemCreationClient(
            itemSequences: ["nested": [insideFolder, outsideFolder]]
        )
        let creator = VaultItemCreator(driveClient: client)

        do {
            _ = try await creator.createMarkdownFile(
                name: "note",
                parentFolderID: "nested",
                in: makeTree()
            )
            XCTFail("Expected post-create boundary violation")
        } catch {
            XCTAssertEqual(error as? DriveError, .vaultBoundaryViolation)
        }

        let trashedItemIDs = await client.trashedItemIDs
        XCTAssertEqual(trashedItemIDs, ["created-file"])
    }

    func testCleanupFailureAfterBoundaryRaceHasUnknownWriteStatus() async {
        let insideFolder = DriveItem(
            id: "nested",
            name: "Nested",
            kind: .folder,
            parentIDs: ["vault"]
        )
        let outsideFolder = DriveItem(
            id: "nested",
            name: "Nested",
            kind: .folder,
            parentIDs: ["outside"]
        )
        let client = FakeItemCreationClient(
            itemSequences: ["nested": [insideFolder, outsideFolder]],
            trashResult: .failure(.permissionDenied)
        )
        let creator = VaultItemCreator(driveClient: client)

        do {
            _ = try await creator.createMarkdownFile(
                name: "note",
                parentFolderID: "nested",
                in: makeTree()
            )
            XCTFail("Expected ambiguous cleanup result")
        } catch {
            XCTAssertEqual(error as? DriveError, .writeStatusUnknown)
        }

        let trashedItemIDs = await client.trashedItemIDs
        XCTAssertEqual(trashedItemIDs, ["created-file"])
    }

    private func makeTree() -> VaultTree {
        VaultTree(
            root: DriveTreeNode(
                item: DriveItem(id: "vault", name: "Vault", kind: .folder),
                children: [
                    DriveTreeNode(
                        item: DriveItem(
                            id: "nested",
                            name: "Nested",
                            kind: .folder,
                            parentIDs: ["vault"]
                        )
                    )
                ]
            )
        )
    }
}

private actor FakeItemCreationClient: DriveItemCreationClient {
    struct FileCreation: Sendable {
        let name: String
        let parentID: String
        let data: Data
        let mimeType: String
    }

    struct FolderCreation: Sendable {
        let name: String
        let parentID: String
    }

    private var itemSequences: [String: [DriveItem]]
    private var createdItems: [String: DriveItem] = [:]
    private let trashResult: Result<Void, DriveError>
    private(set) var fileCreations: [FileCreation] = []
    private(set) var folderCreations: [FolderCreation] = []
    private(set) var trashedItemIDs: [String] = []

    init(
        items: [String: DriveItem] = [:],
        itemSequences: [String: [DriveItem]] = [:],
        trashResult: Result<Void, DriveError> = .success(())
    ) {
        self.itemSequences = items.mapValues { [$0] }
        self.trashResult = trashResult
        for (id, sequence) in itemSequences {
            self.itemSequences[id] = sequence
        }
    }

    func getItem(id: String) async throws -> DriveItem {
        if id == "vault" {
            return DriveItem(id: "vault", name: "Vault", kind: .folder)
        }
        if let createdItem = createdItems[id] {
            return createdItem
        }
        guard var sequence = itemSequences[id], let item = sequence.first else {
            throw DriveError.itemNotFound
        }
        if sequence.count > 1 {
            sequence.removeFirst()
            itemSequences[id] = sequence
        }
        return item
    }

    func createFile(
        name: String,
        parentID: String,
        data: Data,
        mimeType: String
    ) async throws -> DriveFileMetadata {
        fileCreations.append(
            FileCreation(name: name, parentID: parentID, data: data, mimeType: mimeType)
        )
        let item = DriveItem(
            id: "created-file",
            name: name,
            kind: .file,
            mimeType: mimeType,
            parentIDs: [parentID]
        )
        createdItems[item.id] = item
        return DriveFileMetadata(
            item: item,
            revision: DriveFileRevision(version: "1", modifiedTime: .distantPast)
        )
    }

    func createFolder(name: String, parentID: String) async throws -> DriveItem {
        folderCreations.append(FolderCreation(name: name, parentID: parentID))
        let item = DriveItem(
            id: "created-folder",
            name: name,
            kind: .folder,
            mimeType: GoogleDriveAPIClient.folderMimeType,
            parentIDs: [parentID]
        )
        createdItems[item.id] = item
        return item
    }

    func trashItem(id: String) async throws -> DriveItem {
        trashedItemIDs.append(id)
        try trashResult.get()
        return DriveItem(
            id: id,
            name: "Recovered item",
            kind: .file,
            isTrashed: true
        )
    }
}
