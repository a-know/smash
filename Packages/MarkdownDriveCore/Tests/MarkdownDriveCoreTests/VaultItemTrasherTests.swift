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

    func testFallsBackToMarkedVaultFolderWhenDriveTrashIsUnavailable() async throws {
        let file = item(
            id: "note",
            name: "Note.md",
            kind: .file,
            canTrash: false,
            canMoveItemWithinDrive: true
        )
        let controlFolder = DriveItem(
            id: "soft-trash",
            name: VaultSoftTrashMetadata.folderName,
            kind: .folder,
            mimeType: GoogleDriveAPIClient.folderMimeType,
            parentIDs: ["vault"],
            appProperties: [
                VaultSoftTrashMetadata.controlFolderKey:
                    VaultSoftTrashMetadata.controlFolderValue
            ]
        )
        let client = FakeSoftTrashClient(items: [
            "note": file,
            "soft-trash": controlFolder,
        ])
        let trasher = VaultItemTrasher(
            driveClient: client,
            now: { Date(timeIntervalSince1970: 0) }
        )

        let result = try await trasher.trash(
            itemID: "note",
            in: tree(child: file),
            softTrashFolderID: "soft-trash"
        )

        XCTAssertEqual(result.disposition, .vaultSoftTrash)
        XCTAssertEqual(result.softTrashFolderID, "soft-trash")
        XCTAssertFalse(result.item.isTrashed)
        XCTAssertEqual(result.item.parentIDs, ["soft-trash"])
        XCTAssertEqual(
            result.item.appProperties?[VaultSoftTrashMetadata.previousParentIDKey],
            "vault"
        )
        XCTAssertEqual(
            result.item.appProperties?[VaultSoftTrashMetadata.deletedAtKey],
            "1970-01-01T00:00:00Z"
        )
        let operations = await client.operations
        XCTAssertEqual(operations, ["metadata:note", "move:note:vault:soft-trash"])
    }

    func testReconciliationRecognizesVaultSoftTrash() async throws {
        let controlFolder = DriveItem(
            id: "soft-trash",
            name: "Renamed by user",
            kind: .folder,
            parentIDs: ["vault"],
            appProperties: [
                VaultSoftTrashMetadata.controlFolderKey:
                    VaultSoftTrashMetadata.controlFolderValue
            ]
        )
        let file = DriveItem(
            id: "note",
            name: "Note.md",
            kind: .file,
            parentIDs: ["soft-trash"],
            appProperties: [VaultSoftTrashMetadata.softDeletedKey: "true"]
        )
        let client = FakeSoftTrashClient(items: [
            "note": file,
            "soft-trash": controlFolder,
        ])
        let trasher = VaultItemTrasher(driveClient: client)

        let result = try await trasher.reconcile(itemID: "note", in: tree())

        XCTAssertEqual(result, .vaultSoftTrashed(folderID: "soft-trash"))
    }

    func testPostMoveVerificationFailureHasUnknownStatus() async {
        let file = item(
            id: "note",
            name: "Note.md",
            kind: .file,
            canTrash: false,
            canMoveItemWithinDrive: true
        )
        let controlFolder = DriveItem(
            id: "soft-trash",
            name: VaultSoftTrashMetadata.folderName,
            kind: .folder,
            parentIDs: ["vault"],
            appProperties: [
                VaultSoftTrashMetadata.controlFolderKey:
                    VaultSoftTrashMetadata.controlFolderValue
            ]
        )
        let client = FakeSoftTrashClient(
            items: ["note": file, "soft-trash": controlFolder],
            verificationErrorAfterMove: .networkFailure
        )
        let trasher = VaultItemTrasher(driveClient: client)

        do {
            _ = try await trasher.trash(
                itemID: "note",
                in: tree(child: file),
                softTrashFolderID: "soft-trash"
            )
            XCTFail("Expected unknown move status")
        } catch {
            XCTAssertEqual(error as? DriveError, .writeStatusUnknown)
        }
        let moveRequests = await client.moveRequests
        XCTAssertEqual(moveRequests, ["note:vault:soft-trash"])
    }

    func testPostMoveAuthenticationFailureHasUnknownStatus() async {
        let file = item(
            id: "note",
            name: "Note.md",
            kind: .file,
            canTrash: false,
            canMoveItemWithinDrive: true
        )
        let controlFolder = markedControlFolder()
        let client = FakeSoftTrashClient(
            items: ["note": file, "soft-trash": controlFolder],
            verificationErrorAfterMove: .authenticationRequired
        )
        let trasher = VaultItemTrasher(driveClient: client)

        do {
            _ = try await trasher.trash(
                itemID: "note",
                in: tree(child: file),
                softTrashFolderID: "soft-trash"
            )
            XCTFail("Expected unknown move status")
        } catch {
            XCTAssertEqual(error as? DriveError, .writeStatusUnknown)
        }
        let moveRequests = await client.moveRequests
        XCTAssertEqual(moveRequests, ["note:vault:soft-trash"])
    }

    func testControlFolderMovedAfterItemMoveHasUnknownStatus() async {
        let file = item(
            id: "note",
            name: "Note.md",
            kind: .file,
            canTrash: false,
            canMoveItemWithinDrive: true
        )
        let controlFolder = markedControlFolder()
        let client = FakeSoftTrashClient(
            items: ["note": file, "soft-trash": controlFolder],
            movesControlFolderOutsideAfterMove: true
        )
        let trasher = VaultItemTrasher(driveClient: client)

        do {
            _ = try await trasher.trash(
                itemID: "note",
                in: tree(child: file),
                softTrashFolderID: "soft-trash"
            )
            XCTFail("Expected unknown control folder status")
        } catch {
            XCTAssertEqual(error as? DriveError, .writeStatusUnknown)
        }
        let moveRequests = await client.moveRequests
        XCTAssertEqual(moveRequests, ["note:vault:soft-trash"])
    }

    func testReconciliationRejectsMarkedFolderOutsideSelectedVault() async throws {
        let controlFolder = markedControlFolder(parentID: "other-vault")
        let file = softDeletedItem(parentID: controlFolder.id)
        let client = FakeSoftTrashClient(items: [
            "note": file,
            "soft-trash": controlFolder,
        ])
        let trasher = VaultItemTrasher(driveClient: client)

        let result = try await trasher.reconcile(itemID: "note", in: tree())

        XCTAssertEqual(result, .notTrashed)
    }

    func testReconciliationRejectsTrashedMarkedFolder() async throws {
        let controlFolder = markedControlFolder(isTrashed: true)
        let file = softDeletedItem(parentID: controlFolder.id)
        let client = FakeSoftTrashClient(items: [
            "note": file,
            "soft-trash": controlFolder,
        ])
        let trasher = VaultItemTrasher(driveClient: client)

        let result = try await trasher.reconcile(itemID: "note", in: tree())

        XCTAssertEqual(result, .notTrashed)
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

        let result = try await trasher.reconcile(itemID: "note", in: tree(child: file))

        XCTAssertEqual(result, .trashed)
    }

    func testReconciliationConfirmsItemWasNotTrashed() async throws {
        let file = item(id: "note", name: "Note.md", kind: .file, canTrash: true)
        let client = FakeTrashClient(currentItems: ["note": file])
        let trasher = VaultItemTrasher(driveClient: client)

        let result = try await trasher.reconcile(itemID: "note", in: tree(child: file))

        XCTAssertEqual(result, .notTrashed)
    }

    func testReconciliationRejectsMismatchedResponseIdentity() async {
        let other = item(id: "other", name: "Other.md", kind: .file, canTrash: true)
        let client = FakeTrashClient(currentItems: ["note": other])
        let trasher = VaultItemTrasher(driveClient: client)

        do {
            _ = try await trasher.reconcile(itemID: "note", in: tree())
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

    private func markedControlFolder(
        parentID: String = "vault",
        isTrashed: Bool = false
    ) -> DriveItem {
        DriveItem(
            id: "soft-trash",
            name: VaultSoftTrashMetadata.folderName,
            kind: .folder,
            parentIDs: [parentID],
            isTrashed: isTrashed,
            appProperties: [
                VaultSoftTrashMetadata.controlFolderKey:
                    VaultSoftTrashMetadata.controlFolderValue
            ]
        )
    }

    private func softDeletedItem(parentID: String) -> DriveItem {
        DriveItem(
            id: "note",
            name: "Note.md",
            kind: .file,
            parentIDs: [parentID],
            appProperties: [VaultSoftTrashMetadata.softDeletedKey: "true"]
        )
    }

    private func item(
        id: String,
        name: String,
        kind: DriveItemKind,
        parentIDs: [String] = ["vault"],
        canTrash: Bool,
        canMoveItemWithinDrive: Bool? = nil
    ) -> DriveItem {
        DriveItem(
            id: id,
            name: name,
            kind: kind,
            mimeType: kind == .folder ? GoogleDriveAPIClient.folderMimeType : "text/markdown",
            parentIDs: parentIDs,
            capabilities: DriveItemCapabilities(
                canTrash: canTrash,
                canMoveItemWithinDrive: canMoveItemWithinDrive
            )
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

private actor FakeSoftTrashClient: DriveSoftTrashClient {
    private var items: [String: DriveItem]
    private let verificationErrorAfterMove: DriveError?
    private let movesControlFolderOutsideAfterMove: Bool
    private(set) var operations: [String] = []
    private(set) var moveRequests: [String] = []

    init(
        items: [String: DriveItem],
        verificationErrorAfterMove: DriveError? = nil,
        movesControlFolderOutsideAfterMove: Bool = false
    ) {
        self.items = items
        self.verificationErrorAfterMove = verificationErrorAfterMove
        self.movesControlFolderOutsideAfterMove = movesControlFolderOutsideAfterMove
    }

    func getItem(id: String) async throws -> DriveItem {
        if let verificationErrorAfterMove,
            operations.contains(where: { $0.hasPrefix("move:") }),
            id == "note"
        {
            throw verificationErrorAfterMove
        }
        guard let item = items[id] else {
            throw DriveError.itemNotFound
        }
        return item
    }

    func listChildren(of folderID: String) async throws -> [DriveItem] {
        items.values.filter { $0.parentIDs.contains(folderID) && !$0.isTrashed }
    }

    func trashItem(id: String) async throws -> DriveItem {
        throw DriveError.trashNotAllowed
    }

    func createFolder(
        name: String,
        parentID: String,
        appProperties: [String: String]
    ) async throws -> DriveItem {
        let folder = DriveItem(
            id: "created-soft-trash",
            name: name,
            kind: .folder,
            parentIDs: [parentID],
            appProperties: appProperties
        )
        items[folder.id] = folder
        operations.append("create:\(folder.id)")
        return folder
    }

    func updateAppProperties(
        id: String,
        appProperties: [String: String]
    ) async throws -> DriveItem {
        guard let item = items[id] else {
            throw DriveError.itemNotFound
        }
        let updated = DriveItem(
            id: item.id,
            name: item.name,
            kind: item.kind,
            mimeType: item.mimeType,
            parentIDs: item.parentIDs,
            isTrashed: item.isTrashed,
            capabilities: item.capabilities,
            appProperties: appProperties
        )
        items[id] = updated
        operations.append("metadata:\(id)")
        return updated
    }

    func moveItem(
        id: String,
        fromParentID: String,
        toParentID: String
    ) async throws -> DriveItem {
        moveRequests.append("\(id):\(fromParentID):\(toParentID)")
        guard let item = items[id], item.parentIDs == [fromParentID] else {
            throw DriveError.itemChangedRemotely
        }
        let moved = DriveItem(
            id: item.id,
            name: item.name,
            kind: item.kind,
            mimeType: item.mimeType,
            parentIDs: [toParentID],
            isTrashed: item.isTrashed,
            capabilities: item.capabilities,
            appProperties: item.appProperties
        )
        items[id] = moved
        if movesControlFolderOutsideAfterMove,
            let controlFolder = items[toParentID]
        {
            items[toParentID] = DriveItem(
                id: controlFolder.id,
                name: controlFolder.name,
                kind: controlFolder.kind,
                mimeType: controlFolder.mimeType,
                parentIDs: ["outside"],
                isTrashed: controlFolder.isTrashed,
                capabilities: controlFolder.capabilities,
                appProperties: controlFolder.appProperties
            )
        }
        operations.append("move:\(id):\(fromParentID):\(toParentID)")
        return moved
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
