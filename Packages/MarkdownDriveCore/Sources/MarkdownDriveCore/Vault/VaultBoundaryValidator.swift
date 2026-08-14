import Foundation

struct VaultBoundaryValidator {
    private let driveItemClient: any DriveItemClient

    init(driveItemClient: any DriveItemClient) {
        self.driveItemClient = driveItemClient
    }

    func currentParentID(
        of item: DriveItem,
        in tree: VaultTree
    ) async throws -> String {
        guard !item.isTrashed else {
            throw DriveError.vaultBoundaryViolation
        }

        let vaultRootID = tree.root.item.id
        for parentID in item.parentIDs {
            if try await hasCurrentPathToVaultRoot(
                from: parentID,
                vaultRootID: vaultRootID
            ) {
                return parentID
            }
        }
        throw DriveError.vaultBoundaryViolation
    }

    private func hasCurrentPathToVaultRoot(
        from startingFolderID: String,
        vaultRootID: String
    ) async throws -> Bool {
        var pendingFolderIDs = [startingFolderID]
        var visitedFolderIDs: Set<String> = []

        while let folderID = pendingFolderIDs.popLast() {
            if folderID == vaultRootID {
                return true
            }
            guard visitedFolderIDs.insert(folderID).inserted else {
                continue
            }

            let folder: DriveItem
            do {
                folder = try await driveItemClient.getItem(id: folderID)
            } catch DriveError.itemNotFound {
                continue
            }
            guard folder.kind == .folder, !folder.isTrashed else {
                continue
            }
            pendingFolderIDs.append(contentsOf: folder.parentIDs)
        }

        return false
    }
}
