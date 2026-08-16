import Foundation
import XCTest

@testable import MarkdownDriveCore

final class GoogleDriveAPIClientTests: XCTestCase {
    func testListChildrenFetchesEveryPageAndMapsFilesAndFolders() async throws {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(
                statusCode: 200,
                body: """
                    {
                      "files": [
                        {
                          "id": "folder-1",
                          "name": "Work",
                          "mimeType": "application/vnd.google-apps.folder",
                          "parents": ["vault-root"],
                          "trashed": false
                        }
                      ],
                      "nextPageToken": "page-2",
                      "incompleteSearch": false
                    }
                    """
            ),
            .success(
                statusCode: 200,
                body: """
                    {
                      "files": [
                        {
                          "id": "file-1",
                          "name": "memo.md",
                          "mimeType": "text/markdown",
                          "parents": ["vault-root"],
                          "trashed": false
                        }
                      ]
                    }
                    """
            ),
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        let items = try await client.listChildren(of: "vault-root")

        XCTAssertEqual(
            items,
            [
                DriveItem(
                    id: "folder-1",
                    name: "Work",
                    kind: .folder,
                    mimeType: GoogleDriveAPIClient.folderMimeType,
                    parentIDs: ["vault-root"]
                ),
                DriveItem(
                    id: "file-1",
                    name: "memo.md",
                    kind: .file,
                    mimeType: "text/markdown",
                    parentIDs: ["vault-root"]
                ),
            ])

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer fake-access-token")
        XCTAssertEqual(queryValue(named: "q", in: requests[0]), "'vault-root' in parents and trashed = false")
        XCTAssertEqual(queryValue(named: "pageSize", in: requests[0]), "1000")
        XCTAssertEqual(queryValue(named: "supportsAllDrives", in: requests[0]), "true")
        XCTAssertEqual(queryValue(named: "includeItemsFromAllDrives", in: requests[0]), "true")
        XCTAssertNil(queryValue(named: "pageToken", in: requests[0]))
        XCTAssertEqual(queryValue(named: "pageToken", in: requests[1]), "page-2")
    }

    func testListChildrenRejectsIncompleteSearchInsteadOfReturningPartialTree() async {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(
                statusCode: 200,
                body: """
                    {
                      "files": [],
                      "incompleteSearch": true
                    }
                    """
            )
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        do {
            _ = try await client.listChildren(of: "vault-root")
            XCTFail("Expected incomplete search to fail")
        } catch {
            XCTAssertEqual(error as? DriveError, .incompleteSearch)
        }
    }

    func testGetItemMapsHTTPStatusToDomainError() async {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(statusCode: 404, body: "{}")
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        do {
            _ = try await client.getItem(id: "missing")
            XCTFail("Expected missing item to fail")
        } catch {
            XCTAssertEqual(error as? DriveError, .itemNotFound)
        }
    }

    func testSafeReadRefreshesRejectedAccessTokenOnce() async throws {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(statusCode: 401, body: "{}"),
            .success(statusCode: 200, body: fileMetadata(version: "1")),
        ])
        let tokenProvider = FakeDriveAccessTokenProvider(
            refreshedToken: AccessToken(rawValue: "refreshed-access-token")
        )
        let client = GoogleDriveAPIClient(
            accessTokenProvider: tokenProvider,
            transport: transport
        )

        let item = try await client.getItem(id: "file-1")

        XCTAssertEqual(item.id, "file-1")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer fake-access-token"
        )
        XCTAssertEqual(
            requests[1].value(forHTTPHeaderField: "Authorization"),
            "Bearer refreshed-access-token"
        )
        let rejectedTokens = await tokenProvider.rejectedTokens
        XCTAssertEqual(rejectedTokens, [AccessToken(rawValue: "fake-access-token")])
    }

    func testSafeReadDoesNotRetrySecondAuthenticationFailure() async {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(statusCode: 401, body: "{}"),
            .success(statusCode: 401, body: "{}"),
        ])
        let tokenProvider = FakeDriveAccessTokenProvider(
            refreshedToken: AccessToken(rawValue: "refreshed-access-token")
        )
        let client = GoogleDriveAPIClient(
            accessTokenProvider: tokenProvider,
            transport: transport
        )

        do {
            _ = try await client.getItem(id: "file-1")
            XCTFail("Expected repeated authentication failure")
        } catch {
            XCTAssertEqual(error as? DriveError, .authenticationRequired)
        }

        let requests = await transport.requests
        let rejectedTokens = await tokenProvider.rejectedTokens
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(rejectedTokens.count, 1)
    }

    func testDownloadFileReturnsUTF8BytesAndStableRevision() async throws {
        let metadata = """
            {
              "id": "file-1",
              "name": "memo.md",
              "mimeType": "text/markdown",
              "parents": ["vault-root"],
              "trashed": false,
              "modifiedTime": "2026-08-12T12:34:56.123Z",
              "version": "42",
              "capabilities": { "canDownload": true }
            }
            """
        let transport = FakeDriveHTTPTransport(responses: [
            .success(statusCode: 200, body: metadata),
            .success(statusCode: 200, body: "# 日本語\n"),
            .success(statusCode: 200, body: metadata),
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        let download = try await client.downloadFile(id: "file-1")

        XCTAssertEqual(download.item.id, "file-1")
        XCTAssertEqual(download.data, Data("# 日本語\n".utf8))
        XCTAssertEqual(download.revision.version, "42")

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(queryValue(named: "alt", in: requests[1]), "media")
        XCTAssertEqual(queryValue(named: "supportsAllDrives", in: requests[1]), "true")
    }

    func testDownloadFileRejectsRemoteChangeDuringTransfer() async {
        let metadataVersion1 = fileMetadata(version: "1")
        let metadataVersion2 = fileMetadata(version: "2")
        let transport = FakeDriveHTTPTransport(responses: [
            .success(statusCode: 200, body: metadataVersion1),
            .success(statusCode: 200, body: "content"),
            .success(statusCode: 200, body: metadataVersion2),
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        do {
            _ = try await client.downloadFile(id: "file-1")
            XCTFail("Expected changing file to fail")
        } catch {
            XCTAssertEqual(error as? DriveError, .fileChangedDuringDownload)
        }
    }

    func testDownloadFileHonorsDriveDownloadCapability() async {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(
                statusCode: 200,
                body: fileMetadata(version: "1", canDownload: false)
            )
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        do {
            _ = try await client.downloadFile(id: "file-1")
            XCTFail("Expected download restriction")
        } catch {
            XCTAssertEqual(error as? DriveError, .downloadNotAllowed)
        }

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testUpdatesSameDriveFileWithSimpleMediaPatch() async throws {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(statusCode: 200, body: fileMetadata(version: "2"))
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        let metadata = try await client.updateFileContent(
            id: "file-1",
            data: Data("# Updated\n".utf8),
            mimeType: "text/markdown; charset=utf-8"
        )

        XCTAssertEqual(metadata.item.id, "file-1")
        XCTAssertEqual(metadata.revision.version, "2")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PATCH")
        XCTAssertEqual(requests[0].url?.host, "www.googleapis.com")
        XCTAssertEqual(requests[0].url?.path, "/upload/drive/v3/files/file-1")
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer fake-access-token"
        )
        XCTAssertEqual(queryValue(named: "uploadType", in: requests[0]), "media")
        XCTAssertEqual(requests[0].httpBody, Data("# Updated\n".utf8))
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Content-Type"),
            "text/markdown; charset=utf-8"
        )
    }

    func testUpdateClassifiesServerFailureAsUnknownWriteStatus() async {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(statusCode: 503, body: "{}")
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        do {
            _ = try await client.updateFileContent(
                id: "file-1",
                data: Data("new text".utf8),
                mimeType: "text/markdown"
            )
            XCTFail("Expected unknown write status")
        } catch {
            XCTAssertEqual(error as? DriveError, .writeStatusUnknown)
        }
    }

    func testUpdateKeepsAuthenticationFailureDefinite() async {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(statusCode: 401, body: "{}")
        ])
        let tokenProvider = FakeDriveAccessTokenProvider()
        let client = GoogleDriveAPIClient(
            accessTokenProvider: tokenProvider,
            transport: transport
        )

        do {
            _ = try await client.updateFileContent(
                id: "file-1",
                data: Data("new text".utf8),
                mimeType: "text/markdown"
            )
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(error as? DriveError, .authenticationRequired)
        }

        let rejectedTokens = await tokenProvider.rejectedTokens
        XCTAssertTrue(rejectedTokens.isEmpty)
    }

    func testGetsRevisionAndRejectsModificationRestriction() async {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(
                statusCode: 200,
                body: fileMetadata(version: "1", canModifyContent: false)
            )
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        do {
            _ = try await client.getFileMetadata(id: "file-1")
            XCTFail("Expected modification restriction")
        } catch {
            XCTAssertEqual(error as? DriveError, .modificationNotAllowed)
        }
    }

    func testGetsRevisionForRenameWithoutContentModificationCapability() async throws {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(
                statusCode: 200,
                body: fileMetadata(
                    version: "4",
                    canModifyContent: false,
                    canRename: true
                )
            )
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        let metadata = try await client.getFileRevision(id: "file-1")

        XCTAssertEqual(metadata.revision.version, "4")
        XCTAssertEqual(metadata.item.capabilities?.canRename, true)
    }

    func testCreatesConflictCopyWithMultipartUploadInRequestedParent() async throws {
        let createdMetadata = fileMetadata(
            id: "copy-1",
            name: "memo (Conflict Copy).md",
            parentIDs: ["vault"],
            version: "1"
        )
        let transport = FakeDriveHTTPTransport(responses: [
            .success(statusCode: 200, body: createdMetadata)
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        let metadata = try await client.createFile(
            name: "memo (Conflict Copy).md",
            parentID: "vault",
            data: Data("local text".utf8),
            mimeType: "text/markdown; charset=utf-8"
        )

        XCTAssertEqual(metadata.item.id, "copy-1")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/upload/drive/v3/files")
        XCTAssertEqual(queryValue(named: "uploadType", in: requests[0]), "multipart")
        let body = String(decoding: requests[0].httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains(#""name":"memo (Conflict Copy).md""#))
        XCTAssertTrue(body.contains(#""parents":["vault"]"#))
        XCTAssertTrue(body.contains("local text"))
    }

    func testCreateClassifiesMalformedSuccessAsUnknownWriteStatus() async {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(statusCode: 200, body: "not-json")
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        do {
            _ = try await client.createFile(
                name: "copy.md",
                parentID: "vault",
                data: Data("local text".utf8),
                mimeType: "text/markdown"
            )
            XCTFail("Expected unknown write status")
        } catch {
            XCTAssertEqual(error as? DriveError, .writeStatusUnknown)
        }
    }

    func testCreatesFolderWithMetadataOnlyRequestInRequestedParent() async throws {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(
                statusCode: 200,
                body: """
                    {
                      "id": "folder-1",
                      "name": "Projects",
                      "mimeType": "application/vnd.google-apps.folder",
                      "parents": ["vault"],
                      "trashed": false
                    }
                    """
            )
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        let folder = try await client.createFolder(name: "Projects", parentID: "vault")

        XCTAssertEqual(folder.id, "folder-1")
        XCTAssertEqual(folder.kind, .folder)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/drive/v3/files")
        XCTAssertEqual(queryValue(named: "supportsAllDrives", in: requests[0]), "true")
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Content-Type"),
            "application/json; charset=utf-8"
        )
        let body = try XCTUnwrap(requests[0].httpBody)
        let metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(metadata["name"] as? String, "Projects")
        XCTAssertEqual(metadata["parents"] as? [String], ["vault"])
        XCTAssertEqual(
            metadata["mimeType"] as? String,
            "application/vnd.google-apps.folder"
        )
    }

    func testCreateFolderClassifiesServerFailureAsUnknownWriteStatus() async {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(statusCode: 503, body: "{}")
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        do {
            _ = try await client.createFolder(name: "Projects", parentID: "vault")
            XCTFail("Expected unknown create status")
        } catch {
            XCTAssertEqual(error as? DriveError, .writeStatusUnknown)
        }
    }

    func testTrashesItemWithMetadataPatchAndSharedDriveSupport() async throws {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(
                statusCode: 200,
                body: """
                    {
                      "id": "created-file",
                      "name": "Idea.md",
                      "mimeType": "text/markdown",
                      "parents": ["outside"],
                      "trashed": true
                    }
                    """
            )
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        let item = try await client.trashItem(id: "created-file")

        XCTAssertTrue(item.isTrashed)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PATCH")
        XCTAssertEqual(requests[0].url?.path, "/drive/v3/files/created-file")
        XCTAssertEqual(queryValue(named: "supportsAllDrives", in: requests[0]), "true")
        let body = try XCTUnwrap(requests[0].httpBody)
        let metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Bool]
        )
        XCTAssertEqual(metadata, ["trashed": true])
    }

    func testRenamesItemWithMetadataPatchAndSharedDriveSupport() async throws {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(
                statusCode: 200,
                body: fileMetadata(
                    name: "Renamed.md",
                    version: "2",
                    sha256Checksum: "content-sha256",
                    canRename: true
                )
            )
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        let result = try await client.renameItem(id: "file-1", name: "Renamed.md")

        XCTAssertEqual(result.item.name, "Renamed.md")
        XCTAssertEqual(result.item.capabilities?.canRename, true)
        XCTAssertEqual(result.revision?.version, "2")
        XCTAssertEqual(result.revision?.contentChecksum, "content-sha256")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PATCH")
        XCTAssertEqual(requests[0].url?.path, "/drive/v3/files/file-1")
        XCTAssertEqual(queryValue(named: "supportsAllDrives", in: requests[0]), "true")
        let body = try XCTUnwrap(requests[0].httpBody)
        let metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        XCTAssertEqual(metadata, ["name": "Renamed.md"])
    }

    func testListChildrenClassifies403RateLimitReason() async {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(
                statusCode: 403,
                body: """
                    {
                      "error": {
                        "errors": [
                          { "reason": "userRateLimitExceeded" }
                        ]
                      }
                    }
                    """
            )
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        do {
            _ = try await client.listChildren(of: "vault-root")
            XCTFail("Expected rate limit to fail")
        } catch {
            XCTAssertEqual(error as? DriveError, .rateLimited)
        }
    }

    func testListChildrenRejectsRepeatedPageToken() async {
        let repeatedPage = """
            {
              "files": [],
              "nextPageToken": "repeated"
            }
            """
        let transport = FakeDriveHTTPTransport(responses: [
            .success(statusCode: 200, body: repeatedPage),
            .success(statusCode: 200, body: repeatedPage),
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        do {
            _ = try await client.listChildren(of: "vault-root")
            XCTFail("Expected repeated page token to fail")
        } catch {
            XCTAssertEqual(error as? DriveError, .invalidResponse)
        }
    }

    func testListChildrenEscapesDriveQueryLiterals() async throws {
        let transport = FakeDriveHTTPTransport(responses: [
            .success(statusCode: 200, body: #"{"files": []}"#)
        ])
        let client = GoogleDriveAPIClient(
            accessTokenProvider: FakeDriveAccessTokenProvider(),
            transport: transport
        )

        _ = try await client.listChildren(of: "folder'\\id")

        let requests = await transport.requests
        XCTAssertEqual(
            queryValue(named: "q", in: requests[0]),
            #"'folder\'\\id' in parents and trashed = false"#
        )
    }

    private func queryValue(named name: String, in request: URLRequest) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    private func fileMetadata(
        id: String = "file-1",
        name: String = "memo.md",
        parentIDs: [String] = ["vault-root"],
        version: String,
        sha256Checksum: String? = nil,
        canDownload: Bool = true,
        canModifyContent: Bool = true,
        canRename: Bool? = nil
    ) -> String {
        """
        {
          "id": "\(id)",
          "name": "\(name)",
          "mimeType": "text/markdown",
          "parents": \(jsonArray(parentIDs)),
          "trashed": false,
          "modifiedTime": "2026-08-12T12:34:56Z",
          "version": "\(version)",
          \(sha256Checksum.map { "\"sha256Checksum\": \"\($0)\"," } ?? "")
          "capabilities": {
            "canDownload": \(canDownload),
            "canModifyContent": \(canModifyContent)\(canRename.map { ",\n        \"canRename\": \($0)" } ?? "")
          }
        }
        """
    }

    private func jsonArray(_ strings: [String]) -> String {
        let data = try! JSONEncoder().encode(strings)
        return String(decoding: data, as: UTF8.self)
    }
}

private actor FakeDriveAccessTokenProvider: DriveAccessTokenProvider {
    private let refreshedToken: AccessToken
    private(set) var rejectedTokens: [AccessToken] = []

    init(
        refreshedToken: AccessToken = AccessToken(rawValue: "refreshed-access-token")
    ) {
        self.refreshedToken = refreshedToken
    }

    func validAccessToken() async throws -> AccessToken {
        AccessToken(rawValue: "fake-access-token")
    }

    func refreshAccessToken(afterRejected rejectedToken: AccessToken) async throws -> AccessToken {
        rejectedTokens.append(rejectedToken)
        return refreshedToken
    }
}

private actor FakeDriveHTTPTransport: DriveHTTPTransport {
    struct Response: Sendable {
        let statusCode: Int
        let body: Data

        static func success(statusCode: Int, body: String) -> Response {
            Response(statusCode: statusCode, body: Data(body.utf8))
        }
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.removeFirst()
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response.body, httpResponse)
    }
}
