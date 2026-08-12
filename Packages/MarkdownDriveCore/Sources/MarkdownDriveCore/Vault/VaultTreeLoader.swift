import Foundation

public actor VaultTreeLoader {
    private let driveClient: any DriveClient

    public init(driveClient: any DriveClient) {
        self.driveClient = driveClient
    }

    public func load(vault: Vault) async throws -> VaultTree {
        let root = try await driveClient.getItem(id: vault.rootFolderID)
        guard !root.isTrashed else {
            throw DriveError.itemNotFound
        }
        guard root.kind == .folder else {
            throw DriveError.itemIsNotFolder
        }
        return VaultTree(root: try await loadFolder(root, ancestorIDs: []))
    }

    private func loadFolder(
        _ folder: DriveItem,
        ancestorIDs: Set<String>
    ) async throws -> DriveTreeNode {
        guard !ancestorIDs.contains(folder.id) else {
            throw DriveError.invalidHierarchy
        }

        var nextAncestorIDs = ancestorIDs
        nextAncestorIDs.insert(folder.id)
        let items = try await driveClient.listChildren(of: folder.id)
            .filter { !$0.isTrashed }

        var children: [DriveTreeNode] = []
        for item in items {
            switch item.kind {
            case .folder:
                children.append(
                    try await loadFolder(item, ancestorIDs: nextAncestorIDs)
                )
            case .file where MarkdownFileRules.isMarkdownFile(name: item.name):
                children.append(DriveTreeNode(item: item))
            case .file:
                continue
            }
        }

        children.sort(by: Self.isOrderedBefore)
        return DriveTreeNode(item: folder, children: children)
    }

    private static func isOrderedBefore(
        _ lhs: DriveTreeNode,
        _ rhs: DriveTreeNode
    ) -> Bool {
        if lhs.item.kind != rhs.item.kind {
            return lhs.item.kind == .folder
        }
        let nameComparison = lhs.item.name.localizedStandardCompare(rhs.item.name)
        if nameComparison == .orderedSame {
            return lhs.item.id < rhs.item.id
        }
        return nameComparison == .orderedAscending
    }
}
