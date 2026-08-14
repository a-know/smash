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
        let parentID = try await validateCurrentVaultMembership(
            metadata: remoteMetadata,
            document: document,
            tree: tree
        )
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
        } catch DriveError.writeStatusUnknown {
            throw DocumentSaveError.updateStatusUnknown
        } catch {
            throw Self.updateError(from: error)
        }
        try validateWriteResponse(
            metadata: updatedMetadata,
            document: document,
            expectedParentID: parentID
        )

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
        let parentID = try await validateCurrentVaultMembership(
            metadata: remoteMetadata,
            document: document,
            tree: tree
        )

        let copyMetadata: DriveFileMetadata
        do {
            copyMetadata = try await driveWriteClient.createFile(
                name: trimmedName,
                parentID: parentID,
                data: Data(document.text.utf8),
                mimeType: "text/markdown; charset=utf-8"
            )
        } catch DriveError.writeStatusUnknown {
            throw DocumentSaveError.updateStatusUnknown
        } catch {
            throw Self.updateError(from: error)
        }
        guard copyMetadata.item.id != document.fileID,
            copyMetadata.item.kind == .file,
            copyMetadata.item.name == trimmedName,
            copyMetadata.item.parentIDs.contains(parentID),
            !copyMetadata.item.isTrashed
        else {
            throw DocumentSaveError.updateStatusUnknown
        }

        return MarkdownDocument(
            fileID: copyMetadata.item.id,
            name: copyMetadata.item.name,
            text: document.text,
            remoteRevision: copyMetadata.revision
        )
    }

    public func overwriteRemote(
        document: MarkdownDocument,
        in tree: VaultTree
    ) async throws -> MarkdownDocument {
        guard document.isDirty,
            tree.markdownFile(id: document.fileID) != nil
        else {
            throw DocumentSaveError.vaultBoundaryViolation
        }

        let remoteMetadata: DriveFileMetadata
        do {
            remoteMetadata = try await driveWriteClient.getFileMetadata(id: document.fileID)
        } catch {
            throw Self.preflightError(from: error)
        }
        let parentID = try await validateCurrentVaultMembership(
            metadata: remoteMetadata,
            document: document,
            tree: tree
        )

        let updatedMetadata: DriveFileMetadata
        do {
            updatedMetadata = try await driveWriteClient.updateFileContent(
                id: document.fileID,
                data: Data(document.text.utf8),
                mimeType: "text/markdown; charset=utf-8"
            )
        } catch DriveError.writeStatusUnknown {
            throw DocumentSaveError.updateStatusUnknown
        } catch {
            throw Self.updateError(from: error)
        }
        try validateWriteResponse(
            metadata: updatedMetadata,
            document: document,
            expectedParentID: parentID
        )

        var savedDocument = document
        savedDocument.markSaved(revision: updatedMetadata.revision)
        return savedDocument
    }

    private func validateCurrentVaultMembership(
        metadata: DriveFileMetadata,
        document: MarkdownDocument,
        tree: VaultTree
    ) async throws -> String {
        guard metadata.item.id == document.fileID,
            metadata.item.kind == .file,
            MarkdownFileRules.isMarkdownFile(name: metadata.item.name),
            !metadata.item.isTrashed
        else {
            throw DocumentSaveError.vaultBoundaryViolation
        }

        do {
            return try await VaultBoundaryValidator(driveItemClient: driveWriteClient)
                .currentParentID(of: metadata.item, in: tree)
        } catch {
            throw Self.membershipError(from: error)
        }
    }

    private func validateWriteResponse(
        metadata: DriveFileMetadata,
        document: MarkdownDocument,
        expectedParentID: String
    ) throws {
        guard metadata.item.id == document.fileID,
            metadata.item.kind == .file,
            MarkdownFileRules.isMarkdownFile(name: metadata.item.name),
            metadata.item.parentIDs.contains(expectedParentID),
            !metadata.item.isTrashed
        else {
            throw DocumentSaveError.updateStatusUnknown
        }
    }

    private static func preflightError(from error: any Error) -> DocumentSaveError {
        if let authenticationError = error as? AuthenticationError {
            return .authentication(authenticationError)
        }
        guard let driveError = error as? DriveError else {
            return .unexpected
        }
        if driveError == .authenticationRequired {
            return .authentication(.reauthenticationRequired)
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
        if driveError == .authenticationRequired {
            return .authentication(.reauthenticationRequired)
        }
        return driveError == .itemNotFound ? .remoteDeleted : .drive(driveError)
    }

    private static func membershipError(from error: any Error) -> DocumentSaveError {
        if let authenticationError = error as? AuthenticationError {
            return .authentication(authenticationError)
        }
        guard let driveError = error as? DriveError else {
            return .unexpected
        }
        if driveError == .authenticationRequired {
            return .authentication(.reauthenticationRequired)
        }
        if driveError == .itemNotFound || driveError == .vaultBoundaryViolation {
            return .vaultBoundaryViolation
        }
        return .drive(driveError)
    }
}
