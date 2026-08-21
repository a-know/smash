import Foundation

public actor VaultDocumentLoader {
    private let driveContentClient: any DriveContentClient
    private let documentReadCache: (any MarkdownDocumentReadCache)?

    public init(
        driveContentClient: any DriveContentClient,
        documentReadCache: (any MarkdownDocumentReadCache)? = nil
    ) {
        self.driveContentClient = driveContentClient
        self.documentReadCache = documentReadCache
    }

    public func load(
        fileID: String,
        from tree: VaultTree,
        cacheScope: DriveChangeCursorScope? = nil
    ) async throws -> MarkdownDocument {
        guard tree.markdownFile(id: fileID) != nil else {
            throw DriveError.vaultBoundaryViolation
        }

        let boundaryValidator = VaultBoundaryValidator(driveItemClient: driveContentClient)
        let currentMetadata = try await driveContentClient.getFileMetadata(id: fileID)
        guard currentMetadata.item.id == fileID,
            currentMetadata.item.kind == .file,
            MarkdownFileRules.isMarkdownFile(name: currentMetadata.item.name)
        else {
            throw DriveError.itemIsNotFile
        }
        _ = try await boundaryValidator.currentParentID(of: currentMetadata.item, in: tree)

        if let cacheScope,
            let cachedDocument = try? await documentReadCache?.loadDocument(
                fileID: fileID,
                scope: cacheScope
            ),
            cachedDocument.fileID == fileID,
            cachedDocument.name == currentMetadata.item.name,
            cachedDocument.remoteRevision == currentMetadata.revision
        {
            return cachedDocument
        }

        let download = try await driveContentClient.downloadFile(id: fileID)
        guard download.item.id == fileID,
            download.item.kind == .file,
            MarkdownFileRules.isMarkdownFile(name: download.item.name)
        else {
            throw DriveError.itemIsNotFile
        }
        _ = try await boundaryValidator.currentParentID(of: download.item, in: tree)
        guard let text = String(data: download.data, encoding: .utf8) else {
            throw DriveError.invalidUTF8
        }

        let document = MarkdownDocument(
            fileID: download.item.id,
            name: download.item.name,
            text: text,
            remoteRevision: download.revision
        )
        if let cacheScope {
            try? await documentReadCache?.saveDocument(document, scope: cacheScope)
        }
        return document
    }
}
