import XCTest

@testable import MarkdownDriveCore

final class VaultTreeLoaderTests: XCTestCase {
    func testRecursivelyBuildsFolderFirstNaturallySortedMarkdownTree() async throws {
        let root = folder(id: "vault", name: "Vault")
        let notes = folder(id: "notes", name: "Notes")
        let archive = folder(id: "archive", name: "Archive")
        let client = TreeFakeDriveClient(
            items: ["vault": root],
            children: [
                "vault": [
                    file(id: "z", name: "Z.md"),
                    notes,
                    file(id: "2", name: "Note 2.md"),
                    archive,
                    file(id: "10", name: "Note 10.MD"),
                ],
                "archive": [],
                "notes": [file(id: "nested", name: "Nested.md")],
            ]
        )
        let loader = VaultTreeLoader(driveClient: client)

        let tree = try await loader.load(
            vault: Vault(rootFolderID: "vault", displayName: "Vault")
        )

        XCTAssertEqual(
            tree.root.children.map(\.item.id),
            ["archive", "notes", "2", "10", "z"]
        )
        XCTAssertEqual(tree.root.children[1].children.map(\.item.id), ["nested"])
        XCTAssertEqual(tree.markdownFileCount, 4)
    }

    func testIgnoresNonMarkdownFilesAndDoesNotTraverseTrashedFolders() async throws {
        let root = folder(id: "vault", name: "Vault")
        let trashed = folder(id: "trashed", name: "Trashed", isTrashed: true)
        let client = TreeFakeDriveClient(
            items: ["vault": root],
            children: [
                "vault": [
                    file(id: "text", name: "note.txt"),
                    file(id: "missing", name: "README"),
                    file(id: "markdown", name: "README.md"),
                    trashed,
                ]
            ]
        )
        let loader = VaultTreeLoader(driveClient: client)

        let tree = try await loader.load(
            vault: Vault(rootFolderID: "vault", displayName: "Vault")
        )

        XCTAssertEqual(tree.root.children.map(\.item.id), ["markdown"])
        let requestedFolderIDs = await client.requestedFolderIDs()
        XCTAssertEqual(requestedFolderIDs, ["vault"])
    }

    func testExcludesMarkedAppTrashFolderRegardlessOfItsName() async throws {
        let root = folder(id: "vault", name: "Vault")
        let controlFolder = DriveItem(
            id: "soft-trash",
            name: "User renamed this folder",
            kind: .folder,
            parentIDs: ["vault"],
            appProperties: [
                VaultSoftTrashMetadata.controlFolderKey:
                    VaultSoftTrashMetadata.controlFolderValue
            ]
        )
        let client = TreeFakeDriveClient(
            items: ["vault": root],
            children: [
                "vault": [controlFolder, file(id: "visible", name: "Visible.md")],
                "soft-trash": [file(id: "hidden", name: "Hidden.md")],
            ]
        )
        let loader = VaultTreeLoader(driveClient: client)

        let tree = try await loader.load(
            vault: Vault(rootFolderID: "vault", displayName: "Vault")
        )

        XCTAssertEqual(tree.root.children.map(\.item.id), ["visible"])
        let requestedFolderIDs = await client.requestedFolderIDs()
        XCTAssertEqual(requestedFolderIDs, ["vault"])
    }

    func testRejectsFolderCycleInsteadOfEscapingTraversal() async throws {
        let root = folder(id: "vault", name: "Vault")
        let child = folder(id: "child", name: "Child")
        let client = TreeFakeDriveClient(
            items: ["vault": root],
            children: [
                "vault": [child],
                "child": [root],
            ]
        )
        let loader = VaultTreeLoader(driveClient: client)

        do {
            _ = try await loader.load(
                vault: Vault(rootFolderID: "vault", displayName: "Vault")
            )
            XCTFail("Expected invalid hierarchy")
        } catch {
            XCTAssertEqual(error as? DriveError, .invalidHierarchy)
        }
    }

    func testRejectsVaultRootThatIsNotAFolder() async throws {
        let client = TreeFakeDriveClient(
            items: ["file": file(id: "file", name: "note.md")],
            children: [:]
        )
        let loader = VaultTreeLoader(driveClient: client)

        do {
            _ = try await loader.load(
                vault: Vault(rootFolderID: "file", displayName: "note.md")
            )
            XCTFail("Expected folder validation failure")
        } catch {
            XCTAssertEqual(error as? DriveError, .itemIsNotFolder)
        }
    }

    func testTreatsTrashedVaultRootAsMissing() async throws {
        let client = TreeFakeDriveClient(
            items: [
                "vault": folder(
                    id: "vault",
                    name: "Vault",
                    isTrashed: true
                )
            ],
            children: [:]
        )
        let loader = VaultTreeLoader(driveClient: client)

        do {
            _ = try await loader.load(
                vault: Vault(rootFolderID: "vault", displayName: "Vault")
            )
            XCTFail("Expected missing Vault")
        } catch {
            XCTAssertEqual(error as? DriveError, .itemNotFound)
        }
    }

    private func folder(
        id: String,
        name: String,
        isTrashed: Bool = false
    ) -> DriveItem {
        DriveItem(
            id: id,
            name: name,
            kind: .folder,
            mimeType: GoogleDriveAPIClient.folderMimeType,
            isTrashed: isTrashed
        )
    }

    private func file(id: String, name: String) -> DriveItem {
        DriveItem(id: id, name: name, kind: .file, mimeType: "text/markdown")
    }
}

private actor TreeFakeDriveClient: DriveClient {
    private let items: [String: DriveItem]
    private let children: [String: [DriveItem]]
    private var requestedFolders: [String] = []

    init(items: [String: DriveItem], children: [String: [DriveItem]]) {
        self.items = items
        self.children = children
    }

    func getItem(id: String) async throws -> DriveItem {
        guard let item = items[id] else {
            throw DriveError.itemNotFound
        }
        return item
    }

    func listChildren(of folderID: String) async throws -> [DriveItem] {
        requestedFolders.append(folderID)
        return children[folderID] ?? []
    }

    func requestedFolderIDs() -> [String] {
        requestedFolders
    }
}
