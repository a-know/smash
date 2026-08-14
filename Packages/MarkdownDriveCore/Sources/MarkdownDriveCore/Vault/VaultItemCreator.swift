import Foundation

public actor VaultItemCreator {
    private let driveClient: any DriveItemCreationClient

    public init(driveClient: any DriveItemCreationClient) {
        self.driveClient = driveClient
    }

    public func createMarkdownFile(
        name: String,
        parentFolderID: String,
        in tree: VaultTree
    ) async throws -> DriveFileMetadata {
        let normalizedName = try VaultItemNameRules.markdownFileName(from: name)
        try await validateCurrentDestination(parentFolderID, in: tree)

        let metadata = try await driveClient.createFile(
            name: normalizedName,
            parentID: parentFolderID,
            data: Data(),
            mimeType: "text/markdown; charset=utf-8"
        )
        guard metadata.item.kind == .file,
            metadata.item.name == normalizedName,
            metadata.item.parentIDs.contains(parentFolderID),
            !metadata.item.isTrashed
        else {
            throw DriveError.writeStatusUnknown
        }
        try await verifyCreatedItem(metadata.item, remainsIn: tree)
        return metadata
    }

    public func createFolder(
        name: String,
        parentFolderID: String,
        in tree: VaultTree
    ) async throws -> DriveItem {
        let normalizedName = try VaultItemNameRules.folderName(from: name)
        try await validateCurrentDestination(parentFolderID, in: tree)

        let item = try await driveClient.createFolder(
            name: normalizedName,
            parentID: parentFolderID
        )
        guard item.kind == .folder,
            item.name == normalizedName,
            item.parentIDs.contains(parentFolderID),
            !item.isTrashed
        else {
            throw DriveError.writeStatusUnknown
        }
        try await verifyCreatedItem(item, remainsIn: tree)
        return item
    }

    private func validateCurrentDestination(
        _ folderID: String,
        in tree: VaultTree
    ) async throws {
        guard tree.containsFolder(id: folderID) else {
            throw DriveError.vaultBoundaryViolation
        }

        let currentFolder = try await driveClient.getItem(id: folderID)
        guard currentFolder.kind == .folder else {
            throw DriveError.itemIsNotFolder
        }
        guard !currentFolder.isTrashed else {
            throw DriveError.vaultBoundaryViolation
        }

        if folderID == tree.root.item.id {
            return
        }
        _ = try await VaultBoundaryValidator(driveItemClient: driveClient)
            .currentParentID(of: currentFolder, in: tree)
    }

    private func verifyCreatedItem(
        _ item: DriveItem,
        remainsIn tree: VaultTree
    ) async throws {
        let currentItem: DriveItem
        do {
            currentItem = try await driveClient.getItem(id: item.id)
        } catch {
            throw DriveError.writeStatusUnknown
        }
        do {
            _ = try await VaultBoundaryValidator(driveItemClient: driveClient)
                .currentParentID(of: currentItem, in: tree)
        } catch DriveError.vaultBoundaryViolation {
            do {
                _ = try await driveClient.trashItem(id: item.id)
            } catch {
                throw DriveError.writeStatusUnknown
            }
            throw DriveError.vaultBoundaryViolation
        } catch {
            // Creation succeeded, but its final location could not be confirmed. A retry could
            // create a duplicate, so surface an ambiguous result instead of retrying blindly.
            throw DriveError.writeStatusUnknown
        }
    }
}

public enum VaultItemNameRules {
    public static func markdownFileName(from proposedName: String) throws -> String {
        let name = try validatedName(proposedName)
        if MarkdownFileRules.isMarkdownFile(name: name) {
            return name
        }
        return name + MarkdownFileRules.requiredExtension
    }

    public static func folderName(from proposedName: String) throws -> String {
        try validatedName(proposedName)
    }

    private static func validatedName(_ proposedName: String) throws -> String {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
            name != ".",
            name != "..",
            !name.contains("/"),
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw DriveError.invalidName
        }
        return name
    }
}
