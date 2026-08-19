public enum DriveChangeReconciliation: Equatable, Sendable {
    case noVaultChanges
    case reloadVaultTree
}

public actor DriveChangeReconciler {
    private let boundaryValidator: VaultBoundaryValidator

    public init(driveItemClient: any DriveItemClient) {
        boundaryValidator = VaultBoundaryValidator(driveItemClient: driveItemClient)
    }

    public func reconcile(
        changes: [DriveChange],
        against tree: VaultTree
    ) async -> DriveChangeReconciliation {
        for change in changes {
            if await requiresReload(change, tree: tree) {
                return .reloadVaultTree
            }
        }
        return .noVaultChanges
    }

    private func requiresReload(
        _ change: DriveChange,
        tree: VaultTree
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
            do {
                _ = try await boundaryValidator.currentParentID(of: item, in: tree)
                return true
            } catch DriveError.vaultBoundaryViolation {
                return false
            } catch {
                return true
            }
        }
    }
}
