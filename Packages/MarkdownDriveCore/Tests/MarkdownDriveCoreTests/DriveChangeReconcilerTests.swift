import MarkdownDriveCore
import XCTest

final class DriveChangeReconcilerTests: XCTestCase {
    func testEmptyAndUnknownRemovedChangesDoNotReloadVault() async {
        let reconciler = DriveChangeReconciler(driveItemClient: ReconciliationDriveClient())
        let tree = vaultTree()

        var result = await reconciler.reconcile(changes: [], against: tree)
        XCTAssertEqual(result, .noVaultChanges)

        result = await reconciler.reconcile(
            changes: [.file(id: "unknown", removed: true, item: nil)],
            against: tree
        )
        XCTAssertEqual(result, .noVaultChanges)
    }

    func testChangeToExistingVaultItemRequiresReloadEvenWhenMovedOrRemoved() async {
        let reconciler = DriveChangeReconciler(driveItemClient: ReconciliationDriveClient())
        let tree = vaultTree()

        var result = await reconciler.reconcile(
            changes: [.file(id: "note", removed: true, item: nil)],
            against: tree
        )
        XCTAssertEqual(result, .reloadVaultTree)

        result = await reconciler.reconcile(
            changes: [
                .file(
                    id: "note",
                    removed: false,
                    item: markdownFile(id: "note", parentIDs: ["outside"])
                )
            ],
            against: tree
        )
        XCTAssertEqual(result, .reloadVaultTree)
    }

    func testNewMarkdownOrFolderDirectlyInsideVaultRequiresReload() async {
        let reconciler = DriveChangeReconciler(driveItemClient: ReconciliationDriveClient())
        let tree = vaultTree()

        var result = await reconciler.reconcile(
            changes: [
                .file(
                    id: "new-note",
                    removed: false,
                    item: markdownFile(id: "new-note", parentIDs: ["nested"])
                )
            ],
            against: tree
        )
        XCTAssertEqual(result, .reloadVaultTree)

        result = await reconciler.reconcile(
            changes: [
                .file(
                    id: "new-folder",
                    removed: false,
                    item: folder(id: "new-folder", parentIDs: ["vault"])
                )
            ],
            against: tree
        )
        XCTAssertEqual(result, .reloadVaultTree)
    }

    func testNewNestedMarkdownUsesCurrentAncestryToDetectVaultBoundary() async {
        let driveClient = ReconciliationDriveClient(
            items: [
                "new-parent": folder(id: "new-parent", parentIDs: ["nested"]),
                "nested": folder(id: "nested", parentIDs: ["vault"]),
            ]
        )
        let reconciler = DriveChangeReconciler(driveItemClient: driveClient)

        let result = await reconciler.reconcile(
            changes: [
                .file(
                    id: "new-note",
                    removed: false,
                    item: markdownFile(id: "new-note", parentIDs: ["new-parent"])
                )
            ],
            against: vaultTree()
        )

        XCTAssertEqual(result, .reloadVaultTree)
    }

    func testUnrelatedMarkdownAndVaultNonMarkdownDoNotReload() async {
        let driveClient = ReconciliationDriveClient(
            items: ["outside": folder(id: "outside", parentIDs: [])]
        )
        let reconciler = DriveChangeReconciler(driveItemClient: driveClient)
        let tree = vaultTree()

        var result = await reconciler.reconcile(
            changes: [
                .file(
                    id: "outside-note",
                    removed: false,
                    item: markdownFile(id: "outside-note", parentIDs: ["outside"])
                )
            ],
            against: tree
        )
        XCTAssertEqual(result, .noVaultChanges)

        result = await reconciler.reconcile(
            changes: [
                .file(
                    id: "image",
                    removed: false,
                    item: regularFile(id: "image", name: "image.png", parentIDs: ["vault"])
                )
            ],
            against: tree
        )
        XCTAssertEqual(result, .noVaultChanges)
    }

    func testSharedDriveOrUncertainBoundaryRequiresSafeReload() async {
        var reconciler = DriveChangeReconciler(driveItemClient: ReconciliationDriveClient())
        var result = await reconciler.reconcile(
            changes: [.sharedDrive(id: "drive", removed: false)],
            against: vaultTree()
        )
        XCTAssertEqual(result, .reloadVaultTree)

        reconciler = DriveChangeReconciler(
            driveItemClient: ReconciliationDriveClient(errors: ["parent": .networkFailure])
        )
        result = await reconciler.reconcile(
            changes: [
                .file(
                    id: "uncertain",
                    removed: false,
                    item: markdownFile(id: "uncertain", parentIDs: ["parent"])
                )
            ],
            against: vaultTree()
        )
        XCTAssertEqual(result, .reloadVaultTree)

        reconciler = DriveChangeReconciler(driveItemClient: ReconciliationDriveClient())
        result = await reconciler.reconcile(
            changes: [
                .file(
                    id: "missing-parent-note",
                    removed: false,
                    item: markdownFile(id: "missing-parent-note", parentIDs: ["missing-parent"])
                )
            ],
            against: vaultTree()
        )
        XCTAssertEqual(result, .reloadVaultTree)
    }

    func testSiblingChangesReuseBoundaryResolutionWithinBatch() async {
        let driveClient = ReconciliationDriveClient(
            items: ["outside": folder(id: "outside", parentIDs: [])]
        )
        let reconciler = DriveChangeReconciler(driveItemClient: driveClient)

        let result = await reconciler.reconcile(
            changes: [
                .file(
                    id: "first",
                    removed: false,
                    item: markdownFile(id: "first", parentIDs: ["outside"])
                ),
                .file(
                    id: "second",
                    removed: false,
                    item: markdownFile(id: "second", parentIDs: ["outside"])
                ),
            ],
            against: vaultTree()
        )

        XCTAssertEqual(result, .noVaultChanges)
        let outsideRequestCount = await driveClient.requestCount(for: "outside")
        XCTAssertEqual(outsideRequestCount, 1)
    }
}

private actor ReconciliationDriveClient: DriveItemClient {
    private let items: [String: DriveItem]
    private let errors: [String: DriveError]
    private var requestCounts: [String: Int] = [:]

    init(
        items: [String: DriveItem] = [:],
        errors: [String: DriveError] = [:]
    ) {
        self.items = items
        self.errors = errors
    }

    func getItem(id: String) async throws -> DriveItem {
        requestCounts[id, default: 0] += 1
        if let error = errors[id] {
            throw error
        }
        guard let item = items[id] else {
            throw DriveError.itemNotFound
        }
        return item
    }

    func requestCount(for id: String) -> Int {
        requestCounts[id, default: 0]
    }
}

private func vaultTree() -> VaultTree {
    VaultTree(
        root: DriveTreeNode(
            item: folder(id: "vault"),
            children: [
                DriveTreeNode(
                    item: folder(id: "nested", parentIDs: ["vault"]),
                    children: [DriveTreeNode(item: markdownFile(id: "note", parentIDs: ["nested"]))]
                )
            ]
        )
    )
}

private func folder(id: String, parentIDs: [String] = []) -> DriveItem {
    DriveItem(
        id: id,
        name: id,
        kind: .folder,
        mimeType: GoogleDriveAPIClient.folderMimeType,
        parentIDs: parentIDs
    )
}

private func markdownFile(id: String, parentIDs: [String]) -> DriveItem {
    regularFile(id: id, name: "\(id).md", parentIDs: parentIDs)
}

private func regularFile(id: String, name: String, parentIDs: [String]) -> DriveItem {
    DriveItem(
        id: id,
        name: name,
        kind: .file,
        mimeType: "application/octet-stream",
        parentIDs: parentIDs
    )
}
