public struct MarkdownDocument: Equatable, Sendable {
    public let fileID: String
    public var name: String
    public private(set) var text: String
    public private(set) var remoteRevision: DriveFileRevision

    private var savedText: String

    public init(
        fileID: String,
        name: String,
        text: String,
        remoteRevision: DriveFileRevision
    ) {
        self.fileID = fileID
        self.name = name
        self.text = text
        self.remoteRevision = remoteRevision
        savedText = text
    }

    public var isDirty: Bool {
        text != savedText
    }

    public mutating func updateText(_ text: String) {
        self.text = text
    }

    public mutating func markSaved(revision: DriveFileRevision) {
        remoteRevision = revision
        savedText = text
    }

    public mutating func recordSavedText(
        _ text: String,
        revision: DriveFileRevision
    ) {
        remoteRevision = revision
        savedText = text
    }
}
