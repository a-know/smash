public actor VaultItemRenamer {
    private let driveClient: any DriveItemMutationClient

    public init(driveClient: any DriveItemMutationClient) {
        self.driveClient = driveClient
    }

    public func rename(
        itemID: String,
        to proposedName: String,
        in tree: VaultTree
    ) async throws -> DriveItemRenameResult {
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
        guard currentItem.capabilities?.canRename != false else {
            throw DriveError.renameNotAllowed
        }

        let name: String
        switch currentItem.kind {
        case .file:
            name = try VaultItemNameRules.markdownFileName(from: proposedName)
        case .folder:
            name = try VaultItemNameRules.folderName(from: proposedName)
        }
        if name == currentItem.name {
            return DriveItemRenameResult(item: currentItem, revision: nil)
        }

        let renameResult = try await driveClient.renameItem(id: itemID, name: name)
        guard renameResult.item.kind == currentItem.kind,
            renameResult.item.name == name,
            !renameResult.item.isTrashed,
            currentItem.kind != .file || renameResult.revision != nil
        else {
            throw DriveError.writeStatusUnknown
        }

        let verifiedItem: DriveItem
        do {
            verifiedItem = try await driveClient.getItem(id: itemID)
            guard verifiedItem.name == name,
                verifiedItem.kind == currentItem.kind,
                !verifiedItem.isTrashed
            else {
                throw DriveError.writeStatusUnknown
            }
            _ = try await VaultBoundaryValidator(driveItemClient: driveClient)
                .currentParentID(of: verifiedItem, in: tree)
        } catch {
            throw DriveError.writeStatusUnknown
        }
        return DriveItemRenameResult(
            item: verifiedItem,
            revision: renameResult.revision
        )
    }
}
