public struct DriveChangeCursor: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
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
