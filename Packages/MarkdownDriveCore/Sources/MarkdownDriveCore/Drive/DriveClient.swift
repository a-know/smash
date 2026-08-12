public protocol DriveClient: Sendable {
    func getItem(id: String) async throws -> DriveItem
    func listChildren(of folderID: String) async throws -> [DriveItem]
}

public protocol DriveAccessTokenProvider: Sendable {
    func validAccessToken() async throws -> AccessToken
}

extension AuthenticationController: DriveAccessTokenProvider {}
