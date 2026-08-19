public struct DriveAccountID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct DriveChangeCursor: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct DriveChangeCursorScope: Codable, Equatable, Hashable, Sendable {
    public let accountID: DriveAccountID
    public let vaultRootFolderID: String

    public init(accountID: DriveAccountID, vaultRootFolderID: String) {
        self.accountID = accountID
        self.vaultRootFolderID = vaultRootFolderID
    }
}

public enum DriveChange: Equatable, Sendable {
    case file(id: String, removed: Bool, item: DriveItem?)
    case sharedDrive(id: String, removed: Bool)
}

public struct DriveChangeBatch: Equatable, Sendable {
    public let changes: [DriveChange]
    public let newCursor: DriveChangeCursor

    public init(changes: [DriveChange], newCursor: DriveChangeCursor) {
        self.changes = changes
        self.newCursor = newCursor
    }
}
