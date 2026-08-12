public struct MarkdownDocument: Equatable, Sendable {
    public let fileID: String
    public var name: String
    public var text: String

    public init(fileID: String, name: String, text: String) {
        self.fileID = fileID
        self.name = name
        self.text = text
    }
}
