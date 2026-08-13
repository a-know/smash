import Foundation

public protocol DriveClient: Sendable {
    func getItem(id: String) async throws -> DriveItem
    func listChildren(of folderID: String) async throws -> [DriveItem]
}

public protocol DriveContentClient: Sendable {
    func downloadFile(id: String) async throws -> DriveFileDownload
}

public struct DriveFileRevision: Equatable, Sendable {
    public let version: String
    public let modifiedTime: Date

    public init(version: String, modifiedTime: Date) {
        self.version = version
        self.modifiedTime = modifiedTime
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

public protocol DriveAccessTokenProvider: Sendable {
    func validAccessToken() async throws -> AccessToken
}

extension AuthenticationController: DriveAccessTokenProvider {}
