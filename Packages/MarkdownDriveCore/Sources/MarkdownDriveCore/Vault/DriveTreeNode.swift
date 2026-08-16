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

    public func markdownFile(id: String) -> DriveItem? {
        Self.findMarkdownFile(id: id, in: root)
    }

    public func item(id: String) -> DriveItem? {
        Self.findItem(id: id, in: root)
    }

    public func containsFolder(id: String) -> Bool {
        folder(id: id) != nil
    }

    public func folder(id: String) -> DriveItem? {
        Self.findFolder(id: id, in: root)
    }

    private static func countMarkdownFiles(in node: DriveTreeNode) -> Int {
        let currentItemCount = node.item.kind == .file ? 1 : 0
        return currentItemCount
            + node.children.reduce(0) { count, child in
                count + countMarkdownFiles(in: child)
            }
    }

    private static func findMarkdownFile(id: String, in node: DriveTreeNode) -> DriveItem? {
        if node.item.id == id,
            node.item.kind == .file,
            MarkdownFileRules.isMarkdownFile(name: node.item.name)
        {
            return node.item
        }
        return node.children.lazy.compactMap { findMarkdownFile(id: id, in: $0) }.first
    }

    private static func findItem(id: String, in node: DriveTreeNode) -> DriveItem? {
        if node.item.id == id {
            return node.item
        }
        return node.children.lazy.compactMap { findItem(id: id, in: $0) }.first
    }

    private static func findFolder(id: String, in node: DriveTreeNode) -> DriveItem? {
        if node.item.id == id, node.item.kind == .folder {
            return node.item
        }
        return node.children.lazy.compactMap { findFolder(id: id, in: $0) }.first
    }
}
