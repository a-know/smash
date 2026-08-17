public struct Vault: Codable, Equatable, Sendable {
    public let rootFolderID: String
    public var displayName: String
    public var softTrashFolderID: String?

    public init(
        rootFolderID: String,
        displayName: String,
        softTrashFolderID: String? = nil
    ) {
        self.rootFolderID = rootFolderID
        self.displayName = displayName
        self.softTrashFolderID = softTrashFolderID
    }
}
