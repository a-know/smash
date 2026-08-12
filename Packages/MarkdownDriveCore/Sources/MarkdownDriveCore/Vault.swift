public struct Vault: Codable, Equatable, Sendable {
    public let rootFolderID: String
    public var displayName: String

    public init(rootFolderID: String, displayName: String) {
        self.rootFolderID = rootFolderID
        self.displayName = displayName
    }
}
