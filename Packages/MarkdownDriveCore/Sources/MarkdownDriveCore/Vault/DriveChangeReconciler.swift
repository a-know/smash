public enum DriveChangeReconciliation: Equatable, Sendable {
    case noVaultChanges
    case reloadVaultTree
}

public actor DriveChangeReconciler {
    private enum BoundaryResolution {
        case insideVault
        case outsideVault
        case uncertain
    }

    private let driveItemClient: any DriveItemClient

    public init(driveItemClient: any DriveItemClient) {
        self.driveItemClient = driveItemClient
    }

    public func reconcile(
        changes: [DriveChange],
        against tree: VaultTree
    ) async -> DriveChangeReconciliation {
        var boundaryCache: [String: BoundaryResolution] = [:]
        for change in changes {
            if await requiresReload(change, tree: tree, boundaryCache: &boundaryCache) {
                return .reloadVaultTree
            }
        }
        return .noVaultChanges
    }

    private func requiresReload(
        _ change: DriveChange,
        tree: VaultTree,
        boundaryCache: inout [String: BoundaryResolution]
    ) async -> Bool {
        switch change {
        case .sharedDrive:
            return true
        case .file(let id, let removed, let item):
            if tree.item(id: id) != nil {
                return true
            }
            guard !removed, let item, !item.isTrashed else {
                return false
            }
            guard item.kind == .folder || MarkdownFileRules.isMarkdownFile(name: item.name) else {
                return false
            }
            if item.parentIDs.contains(where: { tree.containsFolder(id: $0) }) {
                return true
            }
            var foundUncertainParent = false
            for parentID in item.parentIDs {
                var visitedFolderIDs: Set<String> = []
                switch await resolveBoundary(
                    from: parentID,
                    vaultRootID: tree.root.item.id,
                    cache: &boundaryCache,
                    visitedFolderIDs: &visitedFolderIDs
                ) {
                case .insideVault:
                    return true
                case .outsideVault:
                    continue
                case .uncertain:
                    foundUncertainParent = true
                }
            }
            return foundUncertainParent
        }
    }

    private func resolveBoundary(
        from folderID: String,
        vaultRootID: String,
        cache: inout [String: BoundaryResolution],
        visitedFolderIDs: inout Set<String>
    ) async -> BoundaryResolution {
        if folderID == vaultRootID {
            return .insideVault
        }
        if let cached = cache[folderID] {
            return cached
        }
        guard visitedFolderIDs.insert(folderID).inserted else {
            return .uncertain
        }
        defer {
            visitedFolderIDs.remove(folderID)
        }

        let folder: DriveItem
        do {
            folder = try await driveItemClient.getItem(id: folderID)
        } catch {
            cache[folderID] = .uncertain
            return .uncertain
        }
        guard folder.kind == .folder, !folder.isTrashed else {
            cache[folderID] = .outsideVault
            return .outsideVault
        }

        var foundUncertainParent = false
        for parentID in folder.parentIDs {
            switch await resolveBoundary(
                from: parentID,
                vaultRootID: vaultRootID,
                cache: &cache,
                visitedFolderIDs: &visitedFolderIDs
            ) {
            case .insideVault:
                cache[folderID] = .insideVault
                return .insideVault
            case .outsideVault:
                continue
            case .uncertain:
                foundUncertainParent = true
            }
        }

        let resolution: BoundaryResolution = foundUncertainParent ? .uncertain : .outsideVault
        cache[folderID] = resolution
        return resolution
    }
}
