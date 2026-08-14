import Foundation

public struct GoogleDriveAPIClient: DriveClient, DriveContentClient, DriveWriteClient,
    DriveItemCreationClient
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
            mimeType: Self.folderMimeType
        )
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let item = try await performItemWrite(request)
        guard item.kind == .folder, !item.isTrashed else {
            throw DriveError.writeStatusUnknown
        }
        return item
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
        mimeType: String
    ) throws -> Data {
        do {
            return try JSONEncoder().encode(
                GoogleDriveCreateFileMetadata(
                    name: name,
                    parents: [parentID],
                    mimeType: mimeType
                )
            )
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
        "id,name,mimeType,parents,trashed,modifiedTime,version,capabilities(canDownload,canModifyContent)"
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

    init(name: String, parents: [String], mimeType: String? = nil) {
        self.name = name
        self.parents = parents
        self.mimeType = mimeType
    }
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

private struct GoogleDriveFile: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let parents: [String]
    let trashed: Bool
    let modifiedTime: Date?
    let version: String?
    let capabilities: GoogleDriveFileCapabilities?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case mimeType
        case parents
        case trashed
        case modifiedTime
        case version
        case capabilities
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        parents = try container.decodeIfPresent([String].self, forKey: .parents) ?? []
        trashed = try container.decodeIfPresent(Bool.self, forKey: .trashed) ?? false
        version = try container.decodeIfPresent(String.self, forKey: .version)
        capabilities = try container.decodeIfPresent(
            GoogleDriveFileCapabilities.self,
            forKey: .capabilities
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
            isTrashed: trashed
        )
    }

    var revision: DriveFileRevision? {
        guard let version, let modifiedTime else {
            return nil
        }
        return DriveFileRevision(version: version, modifiedTime: modifiedTime)
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

    private enum CodingKeys: String, CodingKey {
        case canDownload
        case canModifyContent
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canDownload = try container.decodeIfPresent(Bool.self, forKey: .canDownload) ?? true
        canModifyContent = try container.decodeIfPresent(Bool.self, forKey: .canModifyContent) ?? true
    }
}
