import Foundation

public actor VaultDocumentSaver {
    private let driveWriteClient: any DriveWriteClient

    public init(driveWriteClient: any DriveWriteClient) {
        self.driveWriteClient = driveWriteClient
    }

    public func save(
        document: MarkdownDocument,
        in tree: VaultTree
    ) async throws -> MarkdownDocument {
        guard document.isDirty else {
            return document
        }
        guard tree.markdownFile(id: document.fileID) != nil else {
            throw DocumentSaveError.vaultBoundaryViolation
        }

        let remoteMetadata: DriveFileMetadata
        do {
            remoteMetadata = try await driveWriteClient.getFileMetadata(id: document.fileID)
        } catch {
            throw Self.preflightError(from: error)
        }
        try validate(metadata: remoteMetadata, document: document, tree: tree)
        guard remoteMetadata.revision == document.remoteRevision else {
            throw DocumentSaveError.conflict(remoteRevision: remoteMetadata.revision)
        }

        let updatedMetadata: DriveFileMetadata
        do {
            updatedMetadata = try await driveWriteClient.updateFileContent(
                id: document.fileID,
                data: Data(document.text.utf8),
                mimeType: "text/markdown; charset=utf-8"
            )
        } catch DriveError.networkFailure {
            throw DocumentSaveError.updateStatusUnknown
        } catch {
            throw Self.updateError(from: error)
        }
        try validate(metadata: updatedMetadata, document: document, tree: tree)

        var savedDocument = document
        savedDocument.markSaved(revision: updatedMetadata.revision)
        return savedDocument
    }

    private func validate(
        metadata: DriveFileMetadata,
        document: MarkdownDocument,
        tree: VaultTree
    ) throws {
        guard metadata.item.id == document.fileID,
            metadata.item.kind == .file,
            MarkdownFileRules.isMarkdownFile(name: metadata.item.name),
            metadata.item.parentIDs.contains(where: tree.containsFolder(id:))
        else {
            throw DocumentSaveError.vaultBoundaryViolation
        }
    }

    private static func preflightError(from error: any Error) -> DocumentSaveError {
        guard let driveError = error as? DriveError else {
            return .unexpected
        }
        return driveError == .itemNotFound ? .remoteDeleted : .drive(driveError)
    }

    private static func updateError(from error: any Error) -> DocumentSaveError {
        guard let driveError = error as? DriveError else {
            return .unexpected
        }
        return driveError == .itemNotFound ? .remoteDeleted : .drive(driveError)
    }
}
