import Foundation

public enum VaultItemTrashReconciliation: Equatable, Sendable {
    case trashed
    case vaultSoftTrashed(folderID: String)
    case notTrashed
}

public enum VaultItemTrashDisposition: Equatable, Sendable {
    case googleDriveTrash
    case vaultSoftTrash
}

public struct VaultItemTrashResult: Equatable, Sendable {
    public let item: DriveItem
    public let disposition: VaultItemTrashDisposition
    public let softTrashFolderID: String?

    public init(
        item: DriveItem,
        disposition: VaultItemTrashDisposition,
        softTrashFolderID: String? = nil
    ) {
        self.item = item
        self.disposition = disposition
        self.softTrashFolderID = softTrashFolderID
    }

    public var isTrashed: Bool { item.isTrashed }
    public var kind: DriveItemKind { item.kind }
}

public enum VaultSoftTrashMetadata {
    public static let folderName = "_SMASH_TRASH"
    public static let controlFolderKey = "smashControlFolder"
    public static let controlFolderValue = "trash-v1"
    public static let softDeletedKey = "smashSoftDeleted"
    public static let previousParentIDKey = "smashPreviousParentID"
    public static let deletedAtKey = "smashDeletedAt"

    public static func isControlFolder(_ item: DriveItem) -> Bool {
        item.kind == .folder
            && item.appProperties?[controlFolderKey] == controlFolderValue
    }
}

public actor VaultItemTrasher {
    private let driveClient: any DriveItemTrashClient
    private let now: @Sendable () -> Date

    public init(
        driveClient: any DriveItemTrashClient,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.driveClient = driveClient
        self.now = now
    }

    public func trash(
        itemID: String,
        in tree: VaultTree,
        softTrashFolderID: String? = nil
    ) async throws -> VaultItemTrashResult {
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
        let currentParentID = try await VaultBoundaryValidator(driveItemClient: driveClient)
            .currentParentID(of: currentItem, in: tree)
        if currentItem.capabilities?.canTrash == true {
            return try await moveToGoogleDriveTrash(currentItem)
        }

        guard let softTrashClient = driveClient as? any DriveSoftTrashClient,
            currentItem.capabilities?.canMoveItemWithinDrive == true
        else {
            throw DriveError.trashNotAllowed
        }
        return try await moveToVaultSoftTrash(
            currentItem,
            fromParentID: currentParentID,
            tree: tree,
            persistedFolderID: softTrashFolderID,
            driveClient: softTrashClient
        )
    }

    private func moveToGoogleDriveTrash(_ currentItem: DriveItem) async throws
        -> VaultItemTrashResult
    {
        let trashedItem = try await driveClient.trashItem(id: currentItem.id)
        guard trashedItem.id == currentItem.id,
            trashedItem.kind == currentItem.kind,
            trashedItem.name == currentItem.name,
            trashedItem.isTrashed
        else {
            throw DriveError.writeStatusUnknown
        }
        return VaultItemTrashResult(item: trashedItem, disposition: .googleDriveTrash)
    }

    private func moveToVaultSoftTrash(
        _ currentItem: DriveItem,
        fromParentID: String,
        tree: VaultTree,
        persistedFolderID: String?,
        driveClient: any DriveSoftTrashClient
    ) async throws -> VaultItemTrashResult {
        let controlFolder = try await resolveControlFolder(
            rootFolderID: tree.root.item.id,
            persistedFolderID: persistedFolderID,
            driveClient: driveClient
        )
        guard currentItem.id != controlFolder.id else {
            throw DriveError.vaultRootModificationNotAllowed
        }

        var properties = currentItem.appProperties ?? [:]
        properties[VaultSoftTrashMetadata.softDeletedKey] = "true"
        properties[VaultSoftTrashMetadata.previousParentIDKey] = fromParentID
        properties[VaultSoftTrashMetadata.deletedAtKey] = now().ISO8601Format()

        _ = try await driveClient.updateAppProperties(
            id: currentItem.id,
            appProperties: properties
        )
        let itemWithMetadata = try await driveClient.getItem(id: currentItem.id)
        guard properties.allSatisfy({ itemWithMetadata.appProperties?[$0.key] == $0.value }),
            itemWithMetadata.parentIDs == currentItem.parentIDs,
            !itemWithMetadata.isTrashed
        else {
            throw DriveError.writeStatusUnknown
        }

        _ = try await driveClient.moveItem(
            id: currentItem.id,
            fromParentID: fromParentID,
            toParentID: controlFolder.id
        )
        let movedItem: DriveItem
        do {
            movedItem = try await driveClient.getItem(id: currentItem.id)
            guard movedItem.id == currentItem.id,
                movedItem.kind == currentItem.kind,
                movedItem.name == currentItem.name,
                movedItem.parentIDs == [controlFolder.id],
                !movedItem.isTrashed,
                properties.allSatisfy({ movedItem.appProperties?[$0.key] == $0.value })
            else {
                throw DriveError.writeStatusUnknown
            }
        } catch DriveError.authenticationRequired {
            throw DriveError.authenticationRequired
        } catch {
            throw DriveError.writeStatusUnknown
        }
        return VaultItemTrashResult(
            item: movedItem,
            disposition: .vaultSoftTrash,
            softTrashFolderID: controlFolder.id
        )
    }

    private func resolveControlFolder(
        rootFolderID: String,
        persistedFolderID: String?,
        driveClient: any DriveSoftTrashClient
    ) async throws -> DriveItem {
        if let persistedFolderID {
            let folder = try await driveClient.getItem(id: persistedFolderID)
            guard Self.isValidControlFolder(folder, rootFolderID: rootFolderID) else {
                throw DriveError.invalidResponse
            }
            return folder
        }

        let candidates = try await driveClient.listChildren(of: rootFolderID)
            .filter(VaultSoftTrashMetadata.isControlFolder)
            .filter { !$0.isTrashed && $0.parentIDs == [rootFolderID] }
        guard candidates.count <= 1 else {
            throw DriveError.invalidHierarchy
        }
        if let existing = candidates.first {
            return existing
        }

        let created = try await driveClient.createFolder(
            name: VaultSoftTrashMetadata.folderName,
            parentID: rootFolderID,
            appProperties: [
                VaultSoftTrashMetadata.controlFolderKey:
                    VaultSoftTrashMetadata.controlFolderValue
            ]
        )
        guard Self.isValidControlFolder(created, rootFolderID: rootFolderID) else {
            throw DriveError.writeStatusUnknown
        }
        return created
    }

    private static func isValidControlFolder(
        _ item: DriveItem,
        rootFolderID: String
    ) -> Bool {
        !item.isTrashed
            && item.parentIDs == [rootFolderID]
            && VaultSoftTrashMetadata.isControlFolder(item)
    }

    public func reconcile(itemID: String) async throws -> VaultItemTrashReconciliation {
        let currentItem = try await driveClient.getItem(id: itemID)
        guard currentItem.id == itemID else {
            throw DriveError.writeStatusUnknown
        }
        if currentItem.isTrashed {
            return .trashed
        }
        guard currentItem.appProperties?[VaultSoftTrashMetadata.softDeletedKey] == "true",
            currentItem.parentIDs.count == 1,
            let parentID = currentItem.parentIDs.first
        else {
            return .notTrashed
        }
        let parent = try await driveClient.getItem(id: parentID)
        guard parent.id == parentID else {
            throw DriveError.writeStatusUnknown
        }
        return VaultSoftTrashMetadata.isControlFolder(parent)
            ? .vaultSoftTrashed(folderID: parentID)
            : .notTrashed
    }
}
