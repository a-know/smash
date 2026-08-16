import XCTest

@testable import MarkdownDriveCore

final class VaultItemRenamerTests: XCTestCase {
    func testRenamesMarkdownFileAndPreservesExtension() async throws {
        let original = file(name: "Old.md", canRename: true)
        let renamed = file(name: "New.md", canRename: true)
        let client = FakeRenameClient(
            items: [original, renamed],
            metadataRevisions: [revision("1"), revision("2")]
        )
        let renamer = VaultItemRenamer(driveClient: client)

        let result = try await renamer.rename(
            itemID: "note",
            to: "New",
            in: tree(file: original),
            expectedRevision: revision("1")
        )

        XCTAssertEqual(result.item.name, "New.md")
        XCTAssertEqual(result.revision, revision("2"))
        let requests = await client.renameRequests
        XCTAssertEqual(requests, [RenameRequest(id: "note", name: "New.md")])
    }

    func testRenamesFolderWithoutAddingMarkdownExtension() async throws {
        let original = folder(name: "Old", canRename: true)
        let renamed = folder(name: "New", canRename: true)
        let client = FakeRenameClient(items: [original, renamed])
        let renamer = VaultItemRenamer(driveClient: client)

        let result = try await renamer.rename(
            itemID: "folder",
            to: "New",
            in: tree(folder: original)
        )

        XCTAssertEqual(result.item.name, "New")
    }

    func testAlreadyNormalizedNameDoesNotSendRenameRequest() async throws {
        let original = file(name: "Same.md", canRename: true)
        let client = FakeRenameClient(items: [original])
        let renamer = VaultItemRenamer(driveClient: client)

        let result = try await renamer.rename(
            itemID: "note",
            to: "Same",
            in: tree(file: original)
        )

        XCTAssertEqual(result.item, original)
        XCTAssertNil(result.revision)
        let requests = await client.renameRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testItemAbsentFromLoadedTreeIsRejected() async {
        let client = FakeRenameClient(items: [])
        let renamer = VaultItemRenamer(driveClient: client)

        do {
            _ = try await renamer.rename(
                itemID: "outside",
                to: "Other",
                in: tree()
            )
            XCTFail("Expected Vault boundary violation")
        } catch {
            XCTAssertEqual(error as? DriveError, .vaultBoundaryViolation)
        }
        let requests = await client.renameRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRemoteRenameIsNotOverwritten() async {
        let loaded = file(name: "Old.md", canRename: true)
        let remote = file(name: "Remote.md", canRename: true)
        let client = FakeRenameClient(items: [remote])
        let renamer = VaultItemRenamer(driveClient: client)

        do {
            _ = try await renamer.rename(
                itemID: "note",
                to: "Local",
                in: tree(file: loaded)
            )
            XCTFail("Expected remote rename conflict")
        } catch {
            XCTAssertEqual(error as? DriveError, .itemChangedRemotely)
        }
        let requests = await client.renameRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRemoteContentChangeIsNotHiddenByRename() async {
        let original = file(name: "Old.md", canRename: true)
        let client = FakeRenameClient(
            items: [original],
            metadataRevisions: [revision("3")]
        )
        let renamer = VaultItemRenamer(driveClient: client)

        do {
            _ = try await renamer.rename(
                itemID: "note",
                to: "New",
                in: tree(file: original),
                expectedRevision: revision("1")
            )
            XCTFail("Expected remote content conflict")
        } catch {
            XCTAssertEqual(error as? DriveError, .itemChangedRemotely)
        }
        let requests = await client.renameRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRenameCapabilityIsHonored() async {
        let item = file(name: "Old.md", canRename: false)
        let client = FakeRenameClient(items: [item])
        let renamer = VaultItemRenamer(driveClient: client)

        do {
            _ = try await renamer.rename(
                itemID: "note",
                to: "New",
                in: tree(file: item)
            )
            XCTFail("Expected rename restriction")
        } catch {
            XCTAssertEqual(error as? DriveError, .renameNotAllowed)
        }
        let requests = await client.renameRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testVaultRootCannotBeRenamed() async {
        let client = FakeRenameClient(items: [])
        let renamer = VaultItemRenamer(driveClient: client)

        do {
            _ = try await renamer.rename(
                itemID: "vault",
                to: "Other",
                in: tree()
            )
            XCTFail("Expected Vault root restriction")
        } catch {
            XCTAssertEqual(error as? DriveError, .vaultRootModificationNotAllowed)
        }
    }

    func testPostRenameVerificationFailureHasUnknownStatus() async {
        let original = file(name: "Old.md", canRename: true)
        let renamedResponse = file(name: "New.md", canRename: true)
        let changedAgain = file(name: "Other.md", canRename: true)
        let client = FakeRenameClient(
            items: [original, changedAgain],
            renameResult: DriveItemRenameResult(
                item: renamedResponse,
                revision: revision("2")
            )
        )
        let renamer = VaultItemRenamer(driveClient: client)

        do {
            _ = try await renamer.rename(
                itemID: "note",
                to: "New",
                in: tree(file: original)
            )
            XCTFail("Expected ambiguous rename status")
        } catch {
            XCTAssertEqual(error as? DriveError, .writeStatusUnknown)
        }
    }

    func testPostRenameAuthenticationFailureIsPreserved() async {
        let original = file(name: "Old.md", canRename: true)
        let renamed = file(name: "New.md", canRename: true)
        let client = FakeRenameClient(
            items: [original, renamed],
            metadataRevisions: [revision("1")],
            fileRevisionFailureRequestNumber: 2
        )
        let renamer = VaultItemRenamer(driveClient: client)

        do {
            _ = try await renamer.rename(
                itemID: "note",
                to: "New",
                in: tree(file: original),
                expectedRevision: revision("1")
            )
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(error as? DriveError, .authenticationRequired)
        }
        let renameRequests = await client.renameRequests
        XCTAssertEqual(renameRequests, [RenameRequest(id: "note", name: "New.md")])
    }

    private func tree(file: DriveItem? = nil, folder: DriveItem? = nil) -> VaultTree {
        VaultTree(
            root: DriveTreeNode(
                item: DriveItem(id: "vault", name: "Vault", kind: .folder),
                children: [file, folder].compactMap { $0 }.map { DriveTreeNode(item: $0) }
            )
        )
    }

    private func file(name: String, canRename: Bool) -> DriveItem {
        DriveItem(
            id: "note",
            name: name,
            kind: .file,
            mimeType: "text/markdown",
            parentIDs: ["vault"],
            capabilities: DriveItemCapabilities(canRename: canRename)
        )
    }

    private func folder(name: String, canRename: Bool) -> DriveItem {
        DriveItem(
            id: "folder",
            name: name,
            kind: .folder,
            parentIDs: ["vault"],
            capabilities: DriveItemCapabilities(canRename: canRename)
        )
    }

    private func revision(_ version: String) -> DriveFileRevision {
        DriveFileRevision(version: version, modifiedTime: .distantPast)
    }
}

private struct RenameRequest: Equatable, Sendable {
    let id: String
    let name: String
}

private actor FakeRenameClient: DriveItemMutationClient {
    private var items: [DriveItem]
    private var metadataRevisions: [DriveFileRevision]
    private let renameResult: DriveItemRenameResult?
    private let fileRevisionFailureRequestNumber: Int?
    private var fileRevisionRequestCount = 0
    private(set) var renameRequests: [RenameRequest] = []

    init(
        items: [DriveItem],
        metadataRevisions: [DriveFileRevision] = [],
        renameResult: DriveItemRenameResult? = nil,
        fileRevisionFailureRequestNumber: Int? = nil
    ) {
        self.items = items
        self.metadataRevisions = metadataRevisions
        self.renameResult = renameResult
        self.fileRevisionFailureRequestNumber = fileRevisionFailureRequestNumber
    }

    func getItem(id: String) async throws -> DriveItem {
        guard !items.isEmpty else {
            throw DriveError.itemNotFound
        }
        return items.removeFirst()
    }

    func getFileRevision(id: String) async throws -> DriveFileMetadata {
        fileRevisionRequestCount += 1
        if fileRevisionRequestCount == fileRevisionFailureRequestNumber {
            throw DriveError.authenticationRequired
        }
        guard !items.isEmpty else {
            throw DriveError.itemNotFound
        }
        let item = items.removeFirst()
        let revision: DriveFileRevision
        if metadataRevisions.isEmpty {
            revision =
                renameResult?.revision
                ?? DriveFileRevision(version: "2", modifiedTime: .distantPast)
        } else {
            revision = metadataRevisions.removeFirst()
        }
        return DriveFileMetadata(item: item, revision: revision)
    }

    func renameItem(id: String, name: String) async throws -> DriveItemRenameResult {
        renameRequests.append(RenameRequest(id: id, name: name))
        if let renameResult {
            return renameResult
        }
        guard let current = items.first else {
            throw DriveError.itemNotFound
        }
        return DriveItemRenameResult(
            item: DriveItem(
                id: current.id,
                name: name,
                kind: current.kind,
                mimeType: current.mimeType,
                parentIDs: current.parentIDs,
                capabilities: current.capabilities
            ),
            revision: current.kind == .file
                ? DriveFileRevision(version: "2", modifiedTime: .distantPast)
                : nil
        )
    }
}
