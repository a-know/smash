import Foundation

public protocol DriveItemClient: Sendable {
    func getItem(id: String) async throws -> DriveItem
}

public protocol DriveClient: DriveItemClient {
    func listChildren(of folderID: String) async throws -> [DriveItem]
}

public protocol DriveContentClient: DriveItemClient {
    func downloadFile(id: String) async throws -> DriveFileDownload
}

public protocol DriveFileCreationClient: DriveItemClient {
    func createFile(
        name: String,
        parentID: String,
        data: Data,
        mimeType: String
    ) async throws -> DriveFileMetadata
}

public protocol DriveWriteClient: DriveFileCreationClient {
    func getFileMetadata(id: String) async throws -> DriveFileMetadata
    func updateFileContent(id: String, data: Data, mimeType: String) async throws -> DriveFileMetadata
}

public protocol DriveItemCreationClient: DriveFileCreationClient {
    func createFolder(name: String, parentID: String) async throws -> DriveItem
    func trashItem(id: String) async throws -> DriveItem
}

public protocol DriveItemMutationClient: DriveItemClient {
    func getFileRevision(id: String) async throws -> DriveFileMetadata
    func renameItem(id: String, name: String) async throws -> DriveItemRenameResult
}

public struct DriveItemRenameResult: Equatable, Sendable {
    public let item: DriveItem
    public let revision: DriveFileRevision?

    public init(item: DriveItem, revision: DriveFileRevision?) {
        self.item = item
        self.revision = revision
    }
}

public struct DriveFileRevision: Equatable, Sendable {
    public let version: String
    public let modifiedTime: Date
    public let contentChecksum: String?

    public init(version: String, modifiedTime: Date, contentChecksum: String? = nil) {
        self.version = version
        self.modifiedTime = modifiedTime
        self.contentChecksum = contentChecksum
    }
}

public struct DriveFileDownload: Equatable, Sendable {
    public let item: DriveItem
    public let data: Data
    public let revision: DriveFileRevision

    public init(item: DriveItem, data: Data, revision: DriveFileRevision) {
        self.item = item
        self.data = data
        self.revision = revision
    }
}

public struct DriveFileMetadata: Equatable, Sendable {
    public let item: DriveItem
    public let revision: DriveFileRevision

    public init(item: DriveItem, revision: DriveFileRevision) {
        self.item = item
        self.revision = revision
    }
}

public protocol DriveAccessTokenProvider: Sendable {
    func validAccessToken() async throws -> AccessToken
    func refreshAccessToken(afterRejected rejectedToken: AccessToken) async throws -> AccessToken
}

extension AuthenticationController: DriveAccessTokenProvider {}
