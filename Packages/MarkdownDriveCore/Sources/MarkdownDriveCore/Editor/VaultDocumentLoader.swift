import Foundation

public actor VaultDocumentLoader {
    private let driveContentClient: any DriveContentClient

    public init(driveContentClient: any DriveContentClient) {
        self.driveContentClient = driveContentClient
    }

    public func load(fileID: String, from tree: VaultTree) async throws -> MarkdownDocument {
        guard tree.markdownFile(id: fileID) != nil else {
            throw DriveError.vaultBoundaryViolation
        }

        let boundaryValidator = VaultBoundaryValidator(driveItemClient: driveContentClient)
        let currentItem = try await driveContentClient.getItem(id: fileID)
        guard currentItem.id == fileID,
            currentItem.kind == .file,
            MarkdownFileRules.isMarkdownFile(name: currentItem.name)
        else {
            throw DriveError.itemIsNotFile
        }
        _ = try await boundaryValidator.currentParentID(of: currentItem, in: tree)

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

        return MarkdownDocument(
            fileID: download.item.id,
            name: download.item.name,
            text: text,
            remoteRevision: download.revision
        )
    }
}
