public protocol MarkdownDocumentReadCache: Sendable {
    func loadDocument(
        fileID: String,
        scope: DriveChangeCursorScope
    ) async throws -> MarkdownDocument?

    func saveDocument(
        _ document: MarkdownDocument,
        scope: DriveChangeCursorScope
    ) async throws
}
