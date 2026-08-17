public enum VaultItemTrashReconciliation: Equatable, Sendable {
    case trashed
    case notTrashed
}

public actor VaultItemTrasher {
    private let driveClient: any DriveItemTrashClient

    public init(driveClient: any DriveItemTrashClient) {
        self.driveClient = driveClient
    }

    public func trash(itemID: String, in tree: VaultTree) async throws -> DriveItem {
        guard itemID != tree.root.item.id else {
            throw DriveError.vaultRootModificationNotAllowed
        }
        guard let loadedItem = tree.item(id: itemID) else {
            throw DriveError.vaultBoundaryViolation
        }

        let currentItem = try await driveClient.getItem(id: itemID)
        guard currentItem.kind == loadedItem.kind,
            currentItem.name == loadedItem.name,
            !currentItem.isTrashed
        else {
            throw DriveError.itemChangedRemotely
        }
        _ = try await VaultBoundaryValidator(driveItemClient: driveClient)
            .currentParentID(of: currentItem, in: tree)
        guard currentItem.capabilities?.canTrash == true else {
            throw DriveError.trashNotAllowed
        }

        let trashedItem = try await driveClient.trashItem(id: itemID)
        guard trashedItem.id == currentItem.id,
            trashedItem.kind == currentItem.kind,
            trashedItem.name == currentItem.name,
            trashedItem.isTrashed
        else {
            throw DriveError.writeStatusUnknown
        }
        return trashedItem
    }

    public func reconcile(itemID: String) async throws -> VaultItemTrashReconciliation {
        let currentItem = try await driveClient.getItem(id: itemID)
        guard currentItem.id == itemID else {
            throw DriveError.writeStatusUnknown
        }
        return currentItem.isTrashed ? .trashed : .notTrashed
    }
}
