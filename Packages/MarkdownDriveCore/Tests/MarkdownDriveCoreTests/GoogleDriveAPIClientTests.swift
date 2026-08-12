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
}

private struct FakeDriveAccessTokenProvider: DriveAccessTokenProvider {
    func validAccessToken() async throws -> AccessToken {
        AccessToken(rawValue: "fake-access-token")
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
