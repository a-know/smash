import Foundation

public struct GoogleDriveAPIClient: DriveClient, DriveContentClient {
    public static let folderMimeType = "application/vnd.google-apps.folder"

    private let accessTokenProvider: any DriveAccessTokenProvider
    private let transport: any DriveHTTPTransport
    private let baseURL: URL

    public init(
        accessTokenProvider: any DriveAccessTokenProvider,
        transport: any DriveHTTPTransport = URLSessionDriveHTTPTransport(),
        baseURL: URL = URL(string: "https://www.googleapis.com/drive/v3")!
    ) {
        self.accessTokenProvider = accessTokenProvider
        self.transport = transport
        self.baseURL = baseURL
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

    private func perform(_ request: URLRequest) async throws -> Data {
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

        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(for: response.statusCode, responseBody: data)
        }
        return data
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
        "id,name,mimeType,parents,trashed,modifiedTime,version,capabilities(canDownload)"
    private static let rateLimitReasons = [
        "rateLimitExceeded",
        "sharingRateLimitExceeded",
        "userRateLimitExceeded",
    ]
}

private struct GoogleDriveErrorEnvelope: Decodable {
    let error: GoogleDriveErrorDetails
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
}
