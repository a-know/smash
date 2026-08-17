public enum DriveItemKind: String, Codable, Hashable, Sendable {
    case file
    case folder
}

public struct DriveItemCapabilities: Codable, Hashable, Sendable {
    public let canRename: Bool?
    public let canTrash: Bool?
    public let canMoveItemWithinDrive: Bool?

    public init(
        canRename: Bool? = nil,
        canTrash: Bool? = nil,
        canMoveItemWithinDrive: Bool? = nil
    ) {
        self.canRename = canRename
        self.canTrash = canTrash
        self.canMoveItemWithinDrive = canMoveItemWithinDrive
    }
}

public struct DriveItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public let kind: DriveItemKind
    public let mimeType: String?
    public let parentIDs: [String]
    public var isTrashed: Bool
    public let capabilities: DriveItemCapabilities?
    public let appProperties: [String: String]?

    public init(
        id: String,
        name: String,
        kind: DriveItemKind,
        mimeType: String? = nil,
        parentIDs: [String] = [],
        isTrashed: Bool = false,
        capabilities: DriveItemCapabilities? = nil,
        appProperties: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.mimeType = mimeType
        self.parentIDs = parentIDs
        self.isTrashed = isTrashed
        self.capabilities = capabilities
        self.appProperties = appProperties
    }
}
