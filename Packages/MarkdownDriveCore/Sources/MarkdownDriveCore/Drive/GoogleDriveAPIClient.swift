import Foundation

public struct GoogleDriveAPIClient: DriveClient, DriveContentClient, DriveWriteClient,
    DriveItemCreationClient, DriveItemMutationClient, DriveSoftTrashClient, DriveChangeClient,
    DriveAccountClient
{
    public static let folderMimeType = "application/vnd.google-apps.folder"

    private let accessTokenProvider: any DriveAccessTokenProvider
    private let transport: any DriveHTTPTransport
    private let baseURL: URL
    private let uploadBaseURL: URL

    public init(
        accessTokenProvider: any DriveAccessTokenProvider,
        transport: any DriveHTTPTransport = URLSessionDriveHTTPTransport(),
        baseURL: URL = URL(string: "https://www.googleapis.com/drive/v3")!,
        uploadBaseURL: URL = URL(string: "https://www.googleapis.com/upload/drive/v3")!
    ) {
        self.accessTokenProvider = accessTokenProvider
        self.transport = transport
        self.baseURL = baseURL
        self.uploadBaseURL = uploadBaseURL
    }

    public func getItem(id: String) async throws -> DriveItem {
        try await getFileResource(id: id).driveItem
    }

    public func downloadFile(id: String) async throws -> DriveFileDownload {
        let metadataBeforeDownload = try await getFileResource(id: id)
        try validateDownload(metadataBeforeDownload)
        guard let revisionBeforeDownload = metadataBeforeDownload.revision else {
            throw DriveError.invalidResponse
        }

        let url = baseURL.appendingPathComponent("files").appendingPathComponent(id)
        let request = try await authorizedRequest(
            url: url,
            queryItems: [
                URLQueryItem(name: "alt", value: "media"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
            ]
        )
        let data = try await perform(request)
        let metadataAfterDownload = try await getFileResource(id: id)
        try validateDownload(metadataAfterDownload)
        guard let revisionAfterDownload = metadataAfterDownload.revision else {
            throw DriveError.invalidResponse
        }
        guard revisionBeforeDownload == revisionAfterDownload else {
            throw DriveError.fileChangedDuringDownload
        }

        return DriveFileDownload(
            item: metadataAfterDownload.driveItem,
            data: data,
            revision: revisionAfterDownload
        )
    }

    public func getFileMetadata(id: String) async throws -> DriveFileMetadata {
        let file = try await getFileResource(id: id)
        try validateModification(file)
        return try file.metadata
    }

    public func getReadableFileMetadata(id: String) async throws -> DriveFileMetadata {
        let file = try await getFileResource(id: id)
        try validateDownload(file)
        return try file.metadata
    }

    public func getFileRevision(id: String) async throws -> DriveFileMetadata {
        let file = try await getFileResource(id: id)
        guard file.mimeType != Self.folderMimeType else {
            throw DriveError.itemIsNotFile
        }
        guard !file.trashed else {
            throw DriveError.itemNotFound
        }
        return try file.metadata
    }

    public func updateFileContent(
        id: String,
        data: Data,
        mimeType: String
    ) async throws -> DriveFileMetadata {
        let url = uploadBaseURL.appendingPathComponent("files").appendingPathComponent(id)
        var request = try await authorizedRequest(
            url: url,
            queryItems: [
                URLQueryItem(name: "uploadType", value: "media"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "fields", value: Self.fileFields),
            ]
        )
        request.httpMethod = "PATCH"
        request.httpBody = data
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")

        return try await performWrite(request)
    }

    public func createFile(
        name: String,
        parentID: String,
        data: Data,
        mimeType: String
    ) async throws -> DriveFileMetadata {
        let boundary = "MarkdownDrive-\(UUID().uuidString)"
        let url = uploadBaseURL.appendingPathComponent("files")
        var request = try await authorizedRequest(
            url: url,
            queryItems: [
                URLQueryItem(name: "uploadType", value: "multipart"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "fields", value: Self.fileFields),
            ]
        )
        request.httpMethod = "POST"
        request.httpBody = try multipartBody(
            name: name,
            parentID: parentID,
            data: data,
            mimeType: mimeType,
            boundary: boundary
        )
        request.setValue(
            "multipart/related; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        return try await performWrite(request)
    }

    public func createFolder(name: String, parentID: String) async throws -> DriveItem {
        try await createFolder(name: name, parentID: parentID, appProperties: [:])
    }

    public func createFolder(
        name: String,
        parentID: String,
        appProperties: [String: String]
    ) async throws -> DriveItem {
        let url = baseURL.appendingPathComponent("files")
        var request = try await authorizedRequest(
            url: url,
            queryItems: [
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "fields", value: Self.fileFields),
            ]
        )
        request.httpMethod = "POST"
        request.httpBody = try metadataBody(
            name: name,
            parentID: parentID,
            mimeType: Self.folderMimeType,
            appProperties: appProperties
        )
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let item = try await performItemWrite(request)
        guard item.kind == .folder, !item.isTrashed else {
            throw DriveError.writeStatusUnknown
        }
        return item
    }

    public func updateAppProperties(
        id: String,
        appProperties: [String: String]
    ) async throws -> DriveItem {
        let url = baseURL.appendingPathComponent("files").appendingPathComponent(id)
        var request = try await authorizedRequest(
            url: url,
            queryItems: [
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "fields", value: Self.fileFields),
            ]
        )
        request.httpMethod = "PATCH"
        request.httpBody = try encodeMetadata(
            GoogleDriveAppPropertiesMetadata(appProperties: appProperties)
        )
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        return try await performItemWrite(request)
    }

    public func moveItem(
        id: String,
        fromParentID: String,
        toParentID: String
    ) async throws -> DriveItem {
        let url = baseURL.appendingPathComponent("files").appendingPathComponent(id)
        var request = try await authorizedRequest(
            url: url,
            queryItems: [
                URLQueryItem(name: "addParents", value: toParentID),
                URLQueryItem(name: "removeParents", value: fromParentID),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "fields", value: Self.fileFields),
            ]
        )
        request.httpMethod = "PATCH"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        return try await performItemWrite(request)
    }

    public func trashItem(id: String) async throws -> DriveItem {
        let url = baseURL.appendingPathComponent("files").appendingPathComponent(id)
        var request = try await authorizedRequest(
            url: url,
            queryItems: [
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "fields", value: Self.fileFields),
            ]
        )
        request.httpMethod = "PATCH"
        do {
            request.httpBody = try JSONEncoder().encode(GoogleDriveTrashMetadata(trashed: true))
        } catch {
            throw DriveError.invalidResponse
        }
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let item = try await performItemWrite(request)
        guard item.id == id, item.isTrashed else {
            throw DriveError.writeStatusUnknown
        }
        return item
    }

    public func renameItem(id: String, name: String) async throws -> DriveItemRenameResult {
        let url = baseURL.appendingPathComponent("files").appendingPathComponent(id)
        var request = try await authorizedRequest(
            url: url,
            queryItems: [
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "fields", value: Self.fileFields),
            ]
        )
        request.httpMethod = "PATCH"
        do {
            request.httpBody = try JSONEncoder().encode(GoogleDriveRenameMetadata(name: name))
        } catch {
            throw DriveError.invalidResponse
        }
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let result = try await performRenameWrite(request)
        guard result.item.id == id, result.item.name == name, !result.item.isTrashed else {
            throw DriveError.writeStatusUnknown
        }
        return result
    }

    public func listChildren(of folderID: String) async throws -> [DriveItem] {
        var items: [DriveItem] = []
        var pageToken: String?
        var seenPageTokens: Set<String> = []

        repeat {
            let page = try await listChildrenPage(of: folderID, pageToken: pageToken)
            guard !page.incompleteSearch else {
                throw DriveError.incompleteSearch
            }
            items.append(contentsOf: page.files.map(\.driveItem))
            if let nextPageToken = page.nextPageToken, !nextPageToken.isEmpty {
                guard seenPageTokens.insert(nextPageToken).inserted else {
                    throw DriveError.invalidResponse
                }
                pageToken = nextPageToken
            } else {
                pageToken = nil
            }
        } while pageToken != nil

        return items
    }

    public func getStartChangeCursor() async throws -> DriveChangeCursor {
        let request = try await authorizedRequest(
            url: baseURL.appendingPathComponent("changes/startPageToken"),
            queryItems: [
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "fields", value: "startPageToken"),
            ]
        )
        let response: GoogleDriveStartPageToken = try decode(
            from: await perform(request)
        )
        guard !response.startPageToken.isEmpty else {
            throw DriveError.invalidResponse
        }
        return DriveChangeCursor(rawValue: response.startPageToken)
    }

    public func getCurrentAccountID() async throws -> DriveAccountID {
        let request = try await authorizedRequest(
            url: baseURL.appendingPathComponent("about"),
            queryItems: [
                URLQueryItem(name: "fields", value: "user(permissionId,me)")
            ]
        )
        let response: GoogleDriveAbout = try decode(from: await perform(request))
        guard response.user.me,
            !response.user.permissionID.isEmpty
        else {
            throw DriveError.invalidResponse
        }
        return DriveAccountID(rawValue: response.user.permissionID)
    }

    public func listChanges(since cursor: DriveChangeCursor) async throws -> DriveChangeBatch {
        guard !cursor.rawValue.isEmpty else {
            throw DriveError.invalidResponse
        }

        var changes: [DriveChange] = []
        var pageToken = cursor.rawValue
        var seenPageTokens: Set<String> = [pageToken]

        while true {
            let page = try await listChangesPage(pageToken: pageToken)
            changes.append(contentsOf: try page.changes.map { try $0.driveChange })

            if let nextPageToken = page.nextPageToken, !nextPageToken.isEmpty {
                guard seenPageTokens.insert(nextPageToken).inserted else {
                    throw DriveError.invalidResponse
                }
                pageToken = nextPageToken
                continue
            }

            guard let newStartPageToken = page.newStartPageToken,
                !newStartPageToken.isEmpty
            else {
                throw DriveError.invalidResponse
            }
            return DriveChangeBatch(
                changes: changes,
                newCursor: DriveChangeCursor(rawValue: newStartPageToken)
            )
        }
    }

    private func listChangesPage(pageToken: String) async throws -> GoogleDriveChangeList {
        let request = try await authorizedRequest(
            url: baseURL.appendingPathComponent("changes"),
            queryItems: [
                URLQueryItem(name: "pageToken", value: pageToken),
                URLQueryItem(name: "spaces", value: "drive"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "includeRemoved", value: "true"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                URLQueryItem(
                    name: "fields",
                    value:
                        "nextPageToken,newStartPageToken,changes(changeType,fileId,removed,driveId,file(\(Self.fileFields)))"
                ),
            ]
        )
        do {
            return try decode(from: await perform(request))
        } catch DriveError.unexpectedStatus(let statusCode)
            where statusCode == 400 || statusCode == 410
        {
            throw DriveError.changeCursorInvalid
        }
    }

    private func listChildrenPage(
        of folderID: String,
        pageToken: String?
    ) async throws -> GoogleDriveFileList {
        var queryItems = [
            URLQueryItem(name: "q", value: "'\(escapedQueryLiteral(folderID))' in parents and trashed = false"),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "pageSize", value: "1000"),
            URLQueryItem(name: "fields", value: "nextPageToken,incompleteSearch,files(\(Self.fileFields))"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
        ]
        if let pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        let request = try await authorizedRequest(
            url: baseURL.appendingPathComponent("files"),
            queryItems: queryItems
        )
        return try decodeFileList(from: await perform(request))
    }

    private func getFileResource(id: String) async throws -> GoogleDriveFile {
        let url = baseURL.appendingPathComponent("files").appendingPathComponent(id)
        let request = try await authorizedRequest(
            url: url,
            queryItems: [
                URLQueryItem(name: "fields", value: Self.fileFields),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
            ]
        )
        return try decodeFile(from: await perform(request))
    }

    private func validateDownload(_ file: GoogleDriveFile) throws {
        guard file.mimeType != Self.folderMimeType else {
            throw DriveError.itemIsNotFile
        }
        guard !file.trashed else {
            throw DriveError.itemNotFound
        }
        guard file.capabilities?.canDownload != false else {
            throw DriveError.downloadNotAllowed
        }
    }

    private func validateModification(_ file: GoogleDriveFile) throws {
        guard file.mimeType != Self.folderMimeType else {
            throw DriveError.itemIsNotFile
        }
        guard !file.trashed else {
            throw DriveError.itemNotFound
        }
        guard file.capabilities?.canModifyContent != false else {
            throw DriveError.modificationNotAllowed
        }
    }

    private func multipartBody(
        name: String,
        parentID: String,
        data: Data,
        mimeType: String,
        boundary: String
    ) throws -> Data {
        let metadata = GoogleDriveCreateFileMetadata(name: name, parents: [parentID])
        let metadataData: Data
        do {
            metadataData = try JSONEncoder().encode(metadata)
        } catch {
            throw DriveError.invalidResponse
        }

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadataData)
        body.append(Data("\r\n--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private func metadataBody(
        name: String,
        parentID: String,
        mimeType: String,
        appProperties: [String: String] = [:]
    ) throws -> Data {
        try encodeMetadata(
            GoogleDriveCreateFileMetadata(
                name: name,
                parents: [parentID],
                mimeType: mimeType,
                appProperties: appProperties.isEmpty ? nil : appProperties
            )
        )
    }

    private func encodeMetadata<T: Encodable>(_ metadata: T) throws -> Data {
        do {
            return try JSONEncoder().encode(metadata)
        } catch {
            throw DriveError.invalidResponse
        }
    }

    private func authorizedRequest(
        url: URL,
        queryItems: [URLQueryItem]
    ) async throws -> URLRequest {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DriveError.invalidResponse
        }
        components.queryItems = queryItems
        guard let requestURL = components.url else {
            throw DriveError.invalidResponse
        }

        let accessToken = try await accessTokenProvider.validAccessToken()
        var request = URLRequest(url: requestURL)
        request.setValue("Bearer \(accessToken.rawValue)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(
        _ request: URLRequest,
        retryAfterAuthenticationFailure: Bool = true
    ) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as DriveError {
            throw error
        } catch let error as AuthenticationError {
            throw error
        } catch {
            throw DriveError.networkFailure
        }

        if response.statusCode == 401, retryAfterAuthenticationFailure {
            return try await retryAuthenticatedRead(request)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(for: response.statusCode, responseBody: data)
        }
        return data
    }

    private func retryAuthenticatedRead(_ request: URLRequest) async throws -> Data {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
            authorization.hasPrefix("Bearer ")
        else {
            throw DriveError.authenticationRequired
        }

        let rejectedToken = AccessToken(rawValue: String(authorization.dropFirst("Bearer ".count)))
        let refreshedToken = try await accessTokenProvider.refreshAccessToken(
            afterRejected: rejectedToken
        )
        var retryRequest = request
        retryRequest.setValue(
            "Bearer \(refreshedToken.rawValue)",
            forHTTPHeaderField: "Authorization"
        )
        return try await perform(
            retryRequest,
            retryAfterAuthenticationFailure: false
        )
    }

    private func performWrite(_ request: URLRequest) async throws -> DriveFileMetadata {
        let data: Data
        do {
            data = try await perform(
                request,
                retryAfterAuthenticationFailure: false
            )
        } catch DriveError.networkFailure,
            DriveError.serverUnavailable,
            DriveError.invalidResponse
        {
            throw DriveError.writeStatusUnknown
        }

        do {
            let file = try decodeFile(from: data)
            try validateModification(file)
            return try file.metadata
        } catch {
            // A successful HTTP response means Drive may already have committed the write.
            throw DriveError.writeStatusUnknown
        }
    }

    private func performItemWrite(_ request: URLRequest) async throws -> DriveItem {
        let data: Data
        do {
            data = try await perform(
                request,
                retryAfterAuthenticationFailure: false
            )
        } catch DriveError.networkFailure,
            DriveError.serverUnavailable,
            DriveError.invalidResponse
        {
            throw DriveError.writeStatusUnknown
        }

        do {
            return try decodeFile(from: data).driveItem
        } catch {
            // A successful HTTP response means Drive may already have committed the write.
            throw DriveError.writeStatusUnknown
        }
    }

    private func performRenameWrite(_ request: URLRequest) async throws -> DriveItemRenameResult {
        let data: Data
        do {
            data = try await perform(
                request,
                retryAfterAuthenticationFailure: false
            )
        } catch DriveError.networkFailure,
            DriveError.serverUnavailable,
            DriveError.invalidResponse
        {
            throw DriveError.writeStatusUnknown
        }

        do {
            let file = try decodeFile(from: data)
            return DriveItemRenameResult(item: file.driveItem, revision: file.revision)
        } catch {
            throw DriveError.writeStatusUnknown
        }
    }

    private func decodeFile(from data: Data) throws -> GoogleDriveFile {
        do {
            return try JSONDecoder().decode(GoogleDriveFile.self, from: data)
        } catch {
            throw DriveError.invalidResponse
        }
    }

    private func decodeFileList(from data: Data) throws -> GoogleDriveFileList {
        do {
            return try JSONDecoder().decode(GoogleDriveFileList.self, from: data)
        } catch {
            throw DriveError.invalidResponse
        }
    }

    private func decode<Value: Decodable>(from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw DriveError.invalidResponse
        }
    }

    private func escapedQueryLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private static func error(for statusCode: Int, responseBody: Data) -> DriveError {
        switch statusCode {
        case 401:
            .authenticationRequired
        case 403:
            isRateLimitResponse(responseBody)
                ? .rateLimited
                : .permissionDenied
        case 404:
            .itemNotFound
        case 429:
            .rateLimited
        case 500..<600:
            .serverUnavailable
        default:
            .unexpectedStatus(statusCode)
        }
    }

    private static func decodeErrorReason(from data: Data) -> String? {
        try? JSONDecoder().decode(GoogleDriveErrorEnvelope.self, from: data).error.errors.first?.reason
    }

    private static func isRateLimitResponse(_ data: Data) -> Bool {
        guard let reason = decodeErrorReason(from: data) else {
            return false
        }
        return rateLimitReasons.contains(reason)
    }

    private static let fileFields =
        "id,name,mimeType,parents,trashed,modifiedTime,version,md5Checksum,sha1Checksum,sha256Checksum,appProperties,capabilities(canDownload,canModifyContent,canRename,canTrash,canMoveItemWithinDrive)"
    private static let rateLimitReasons = [
        "rateLimitExceeded",
        "sharingRateLimitExceeded",
        "userRateLimitExceeded",
    ]
}

private struct GoogleDriveErrorEnvelope: Decodable {
    let error: GoogleDriveErrorDetails
}

private struct GoogleDriveCreateFileMetadata: Encodable {
    let name: String
    let parents: [String]
    let mimeType: String?
    let appProperties: [String: String]?

    init(
        name: String,
        parents: [String],
        mimeType: String? = nil,
        appProperties: [String: String]? = nil
    ) {
        self.name = name
        self.parents = parents
        self.mimeType = mimeType
        self.appProperties = appProperties
    }
}

private struct GoogleDriveAppPropertiesMetadata: Encodable {
    let appProperties: [String: String]
}

private struct GoogleDriveTrashMetadata: Encodable {
    let trashed: Bool
}

private struct GoogleDriveRenameMetadata: Encodable {
    let name: String
}

private struct GoogleDriveErrorDetails: Decodable {
    let errors: [GoogleDriveErrorReason]
}

private struct GoogleDriveErrorReason: Decodable {
    let reason: String
}

private struct GoogleDriveFileList: Decodable {
    let files: [GoogleDriveFile]
    let nextPageToken: String?
    let incompleteSearch: Bool

    private enum CodingKeys: String, CodingKey {
        case files
        case nextPageToken
        case incompleteSearch
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decodeIfPresent([GoogleDriveFile].self, forKey: .files) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
        incompleteSearch = try container.decodeIfPresent(Bool.self, forKey: .incompleteSearch) ?? false
    }
}

private struct GoogleDriveStartPageToken: Decodable {
    let startPageToken: String
}

private struct GoogleDriveAbout: Decodable {
    let user: GoogleDriveUser
}

private struct GoogleDriveUser: Decodable {
    let permissionID: String
    let me: Bool

    private enum CodingKeys: String, CodingKey {
        case permissionID = "permissionId"
        case me
    }
}

private struct GoogleDriveChangeList: Decodable {
    let changes: [GoogleDriveChange]
    let nextPageToken: String?
    let newStartPageToken: String?

    private enum CodingKeys: String, CodingKey {
        case changes
        case nextPageToken
        case newStartPageToken
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changes = try container.decodeIfPresent([GoogleDriveChange].self, forKey: .changes) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
        newStartPageToken = try container.decodeIfPresent(String.self, forKey: .newStartPageToken)
    }
}

private struct GoogleDriveChange: Decodable {
    let changeType: String
    let fileID: String?
    let removed: Bool
    let driveID: String?
    let file: GoogleDriveFile?

    private enum CodingKeys: String, CodingKey {
        case changeType
        case fileID = "fileId"
        case removed
        case driveID = "driveId"
        case file
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changeType = try container.decode(String.self, forKey: .changeType)
        fileID = try container.decodeIfPresent(String.self, forKey: .fileID)
        removed = try container.decodeIfPresent(Bool.self, forKey: .removed) ?? false
        driveID = try container.decodeIfPresent(String.self, forKey: .driveID)
        file = try container.decodeIfPresent(GoogleDriveFile.self, forKey: .file)
    }

    var driveChange: DriveChange {
        get throws {
            switch changeType {
            case "file":
                guard let fileID, !fileID.isEmpty else {
                    throw DriveError.invalidResponse
                }
                if removed {
                    guard file == nil || file?.id == fileID else {
                        throw DriveError.invalidResponse
                    }
                    return .file(id: fileID, removed: true, item: file?.driveItem)
                }
                guard let file, file.id == fileID else {
                    throw DriveError.invalidResponse
                }
                return .file(id: fileID, removed: false, item: file.driveItem)
            case "drive":
                guard let driveID, !driveID.isEmpty else {
                    throw DriveError.invalidResponse
                }
                return .sharedDrive(id: driveID, removed: removed)
            default:
                throw DriveError.invalidResponse
            }
        }
    }
}

private struct GoogleDriveFile: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let parents: [String]
    let trashed: Bool
    let modifiedTime: Date?
    let version: String?
    let md5Checksum: String?
    let sha1Checksum: String?
    let sha256Checksum: String?
    let capabilities: GoogleDriveFileCapabilities?
    let appProperties: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case mimeType
        case parents
        case trashed
        case modifiedTime
        case version
        case md5Checksum
        case sha1Checksum
        case sha256Checksum
        case capabilities
        case appProperties
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        parents = try container.decodeIfPresent([String].self, forKey: .parents) ?? []
        trashed = try container.decodeIfPresent(Bool.self, forKey: .trashed) ?? false
        version = try container.decodeIfPresent(String.self, forKey: .version)
        md5Checksum = try container.decodeIfPresent(String.self, forKey: .md5Checksum)
        sha1Checksum = try container.decodeIfPresent(String.self, forKey: .sha1Checksum)
        sha256Checksum = try container.decodeIfPresent(String.self, forKey: .sha256Checksum)
        capabilities = try container.decodeIfPresent(
            GoogleDriveFileCapabilities.self,
            forKey: .capabilities
        )
        appProperties = try container.decodeIfPresent(
            [String: String].self,
            forKey: .appProperties
        )
        if let value = try container.decodeIfPresent(String.self, forKey: .modifiedTime) {
            modifiedTime = Self.parseModifiedTime(value)
        } else {
            modifiedTime = nil
        }
    }

    var driveItem: DriveItem {
        DriveItem(
            id: id,
            name: name,
            kind: mimeType == GoogleDriveAPIClient.folderMimeType ? .folder : .file,
            mimeType: mimeType,
            parentIDs: parents,
            isTrashed: trashed,
            capabilities: capabilities.map {
                DriveItemCapabilities(
                    canRename: $0.canRename,
                    canTrash: $0.canTrash,
                    canMoveItemWithinDrive: $0.canMoveItemWithinDrive
                )
            },
            appProperties: appProperties
        )
    }

    var revision: DriveFileRevision? {
        guard let version, let modifiedTime else {
            return nil
        }
        return DriveFileRevision(
            version: version,
            modifiedTime: modifiedTime,
            contentChecksum: sha256Checksum ?? sha1Checksum ?? md5Checksum
        )
    }

    var metadata: DriveFileMetadata {
        get throws {
            guard let revision else {
                throw DriveError.invalidResponse
            }
            return DriveFileMetadata(item: driveItem, revision: revision)
        }
    }

    private static func parseModifiedTime(_ value: String) -> Date? {
        let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? Date(value, strategy: fractionalStyle) {
            return date
        }
        return try? Date(value, strategy: .iso8601)
    }
}

private struct GoogleDriveFileCapabilities: Decodable {
    let canDownload: Bool
    let canModifyContent: Bool
    let canRename: Bool?
    let canTrash: Bool?
    let canMoveItemWithinDrive: Bool?

    private enum CodingKeys: String, CodingKey {
        case canDownload
        case canModifyContent
        case canRename
        case canTrash
        case canMoveItemWithinDrive
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canDownload = try container.decodeIfPresent(Bool.self, forKey: .canDownload) ?? true
        canModifyContent = try container.decodeIfPresent(Bool.self, forKey: .canModifyContent) ?? true
        canRename = try container.decodeIfPresent(Bool.self, forKey: .canRename)
        canTrash = try container.decodeIfPresent(Bool.self, forKey: .canTrash)
        canMoveItemWithinDrive = try container.decodeIfPresent(
            Bool.self,
            forKey: .canMoveItemWithinDrive
        )
    }
}
