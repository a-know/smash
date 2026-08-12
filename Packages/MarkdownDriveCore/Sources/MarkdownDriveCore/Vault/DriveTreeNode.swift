public struct DriveTreeNode: Equatable, Identifiable, Sendable {
    public let item: DriveItem
    public let children: [DriveTreeNode]

    public init(item: DriveItem, children: [DriveTreeNode] = []) {
        self.item = item
        self.children = children
    }

    public var id: String {
        item.id
    }

    public var outlineChildren: [DriveTreeNode]? {
        children.isEmpty ? nil : children
    }
}

public struct VaultTree: Equatable, Sendable {
    public let root: DriveTreeNode

    public init(root: DriveTreeNode) {
        self.root = root
    }

    public var markdownFileCount: Int {
        Self.countMarkdownFiles(in: root)
    }

    private static func countMarkdownFiles(in node: DriveTreeNode) -> Int {
        let currentItemCount = node.item.kind == .file ? 1 : 0
        return currentItemCount
            + node.children.reduce(0) { count, child in
                count + countMarkdownFiles(in: child)
            }
    }
}
