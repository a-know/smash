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

    public func saveCopy(
        document: MarkdownDocument,
        name: String,
        in tree: VaultTree
    ) async throws -> MarkdownDocument {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
            !trimmedName.contains("/"),
            MarkdownFileRules.isMarkdownFile(name: trimmedName),
            tree.markdownFile(id: document.fileID) != nil
        else {
            throw DocumentSaveError.invalidCopyName
        }

        let remoteMetadata: DriveFileMetadata
        do {
            remoteMetadata = try await driveWriteClient.getFileMetadata(id: document.fileID)
        } catch {
            throw Self.preflightError(from: error)
        }
        try validate(metadata: remoteMetadata, document: document, tree: tree)
        guard let parentID = remoteMetadata.item.parentIDs.first(where: tree.containsFolder(id:)) else {
            throw DocumentSaveError.vaultBoundaryViolation
        }

        let copyMetadata: DriveFileMetadata
        do {
            copyMetadata = try await driveWriteClient.createFile(
                name: trimmedName,
                parentID: parentID,
                data: Data(document.text.utf8),
                mimeType: "text/markdown; charset=utf-8"
            )
        } catch DriveError.networkFailure {
            throw DocumentSaveError.updateStatusUnknown
        } catch {
            throw Self.updateError(from: error)
        }
        guard copyMetadata.item.id != document.fileID,
            copyMetadata.item.kind == .file,
            copyMetadata.item.name == trimmedName,
            copyMetadata.item.parentIDs.contains(parentID)
        else {
            throw DocumentSaveError.vaultBoundaryViolation
        }

        return MarkdownDocument(
            fileID: copyMetadata.item.id,
            name: copyMetadata.item.name,
            text: document.text,
            remoteRevision: copyMetadata.revision
        )
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
        if let authenticationError = error as? AuthenticationError {
            return .authentication(authenticationError)
        }
        guard let driveError = error as? DriveError else {
            return .unexpected
        }
        return driveError == .itemNotFound ? .remoteDeleted : .drive(driveError)
    }

    private static func updateError(from error: any Error) -> DocumentSaveError {
        if let authenticationError = error as? AuthenticationError {
            return .authentication(authenticationError)
        }
        guard let driveError = error as? DriveError else {
            return .unexpected
        }
        return driveError == .itemNotFound ? .remoteDeleted : .drive(driveError)
    }
}
