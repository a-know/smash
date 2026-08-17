import XCTest

@testable import MarkdownDriveCore

final class VaultItemTrasherTests: XCTestCase {
    func testTrashesCurrentVaultFile() async throws {
        let file = item(id: "note", name: "Note.md", kind: .file, canTrash: true)
        let client = FakeTrashClient(
            currentItems: ["note": file],
            trashResult: .success(trashed(file))
        )
        let trasher = VaultItemTrasher(driveClient: client)

        let result = try await trasher.trash(itemID: "note", in: tree(child: file))

        XCTAssertTrue(result.isTrashed)
        let requests = await client.trashRequests
        XCTAssertEqual(requests, ["note"])
    }

    func testTrashesCurrentVaultFolder() async throws {
        let folder = item(id: "folder", name: "Drafts", kind: .folder, canTrash: true)
        let client = FakeTrashClient(
            currentItems: ["folder": folder],
            trashResult: .success(trashed(folder))
        )
        let trasher = VaultItemTrasher(driveClient: client)

        let result = try await trasher.trash(itemID: "folder", in: tree(child: folder))

        XCTAssertTrue(result.isTrashed)
        XCTAssertEqual(result.kind, .folder)
    }

    func testVaultRootCannotBeTrashed() async {
        let client = FakeTrashClient(currentItems: [:])
        let trasher = VaultItemTrasher(driveClient: client)

        do {
            _ = try await trasher.trash(itemID: "vault", in: tree())
            XCTFail("Expected Vault root restriction")
        } catch {
            XCTAssertEqual(error as? DriveError, .vaultRootModificationNotAllowed)
        }
        let requests = await client.trashRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testItemAbsentFromLoadedTreeIsRejected() async {
        let client = FakeTrashClient(currentItems: [:])
        let trasher = VaultItemTrasher(driveClient: client)

        do {
            _ = try await trasher.trash(itemID: "outside", in: tree())
            XCTFail("Expected Vault boundary violation")
        } catch {
            XCTAssertEqual(error as? DriveError, .vaultBoundaryViolation)
        }
        let requests = await client.trashRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRemoteMetadataChangeIsNotTrashed() async {
        let loaded = item(id: "note", name: "Old.md", kind: .file, canTrash: true)
        let remote = item(id: "note", name: "Remote.md", kind: .file, canTrash: true)
        let client = FakeTrashClient(currentItems: ["note": remote])
        let trasher = VaultItemTrasher(driveClient: client)

        do {
            _ = try await trasher.trash(itemID: "note", in: tree(child: loaded))
            XCTFail("Expected remote change")
        } catch {
            XCTAssertEqual(error as? DriveError, .itemChangedRemotely)
        }
        let requests = await client.trashRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testItemMovedOutsideVaultIsNotTrashed() async {
        let loaded = item(id: "note", name: "Note.md", kind: .file, canTrash: true)
        let moved = item(
            id: "note",
            name: "Note.md",
            kind: .file,
            parentIDs: ["outside"],
            canTrash: true
        )
        let outside = item(
            id: "outside",
            name: "Outside",
            kind: .folder,
            parentIDs: ["drive-root"],
            canTrash: false
        )
        let client = FakeTrashClient(currentItems: ["note": moved, "outside": outside])
        let trasher = VaultItemTrasher(driveClient: client)

        do {
            _ = try await trasher.trash(itemID: "note", in: tree(child: loaded))
            XCTFail("Expected Vault boundary violation")
        } catch {
            XCTAssertEqual(error as? DriveError, .vaultBoundaryViolation)
        }
        let requests = await client.trashRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testTrashCapabilityIsRequired() async {
        let file = item(id: "note", name: "Note.md", kind: .file, canTrash: false)
        let client = FakeTrashClient(currentItems: ["note": file])
        let trasher = VaultItemTrasher(driveClient: client)

        do {
            _ = try await trasher.trash(itemID: "note", in: tree(child: file))
            XCTFail("Expected Trash restriction")
        } catch {
            XCTAssertEqual(error as? DriveError, .trashNotAllowed)
        }
        let requests = await client.trashRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testMalformedTrashResultHasUnknownStatus() async {
        let file = item(id: "note", name: "Note.md", kind: .file, canTrash: true)
        let client = FakeTrashClient(
            currentItems: ["note": file],
            trashResult: .success(file)
        )
        let trasher = VaultItemTrasher(driveClient: client)

        do {
            _ = try await trasher.trash(itemID: "note", in: tree(child: file))
            XCTFail("Expected unknown write status")
        } catch {
            XCTAssertEqual(error as? DriveError, .writeStatusUnknown)
        }
        let requests = await client.trashRequests
        XCTAssertEqual(requests, ["note"])
    }

    func testReconciliationConfirmsTrashedItem() async throws {
        let file = item(id: "note", name: "Note.md", kind: .file, canTrash: true)
        let client = FakeTrashClient(currentItems: ["note": trashed(file)])
        let trasher = VaultItemTrasher(driveClient: client)

        let result = try await trasher.reconcile(itemID: "note")

        XCTAssertEqual(result, .trashed)
    }

    func testReconciliationConfirmsItemWasNotTrashed() async throws {
        let file = item(id: "note", name: "Note.md", kind: .file, canTrash: true)
        let client = FakeTrashClient(currentItems: ["note": file])
        let trasher = VaultItemTrasher(driveClient: client)

        let result = try await trasher.reconcile(itemID: "note")

        XCTAssertEqual(result, .notTrashed)
    }

    func testReconciliationRejectsMismatchedResponseIdentity() async {
        let other = item(id: "other", name: "Other.md", kind: .file, canTrash: true)
        let client = FakeTrashClient(currentItems: ["note": other])
        let trasher = VaultItemTrasher(driveClient: client)

        do {
            _ = try await trasher.reconcile(itemID: "note")
            XCTFail("Expected unknown write status")
        } catch {
            XCTAssertEqual(error as? DriveError, .writeStatusUnknown)
        }
    }

    private func tree(child: DriveItem? = nil) -> VaultTree {
        VaultTree(
            root: DriveTreeNode(
                item: DriveItem(id: "vault", name: "Vault", kind: .folder),
                children: child.map { [DriveTreeNode(item: $0)] } ?? []
            )
        )
    }

    private func item(
        id: String,
        name: String,
        kind: DriveItemKind,
        parentIDs: [String] = ["vault"],
        canTrash: Bool
    ) -> DriveItem {
        DriveItem(
            id: id,
            name: name,
            kind: kind,
            mimeType: kind == .folder ? GoogleDriveAPIClient.folderMimeType : "text/markdown",
            parentIDs: parentIDs,
            capabilities: DriveItemCapabilities(canTrash: canTrash)
        )
    }

    private func trashed(_ item: DriveItem) -> DriveItem {
        DriveItem(
            id: item.id,
            name: item.name,
            kind: item.kind,
            mimeType: item.mimeType,
            parentIDs: item.parentIDs,
            isTrashed: true,
            capabilities: item.capabilities
        )
    }
}

private actor FakeTrashClient: DriveItemTrashClient {
    private let currentItems: [String: DriveItem]
    private let trashResult: Result<DriveItem, DriveError>
    private(set) var trashRequests: [String] = []

    init(
        currentItems: [String: DriveItem],
        trashResult: Result<DriveItem, DriveError> = .failure(.itemNotFound)
    ) {
        self.currentItems = currentItems
        self.trashResult = trashResult
    }

    func getItem(id: String) async throws -> DriveItem {
        guard let item = currentItems[id] else {
            throw DriveError.itemNotFound
        }
        return item
    }

    func trashItem(id: String) async throws -> DriveItem {
        trashRequests.append(id)
        return try trashResult.get()
    }
}
