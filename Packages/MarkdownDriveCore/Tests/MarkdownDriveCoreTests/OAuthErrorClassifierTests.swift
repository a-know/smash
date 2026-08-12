import XCTest

@testable import MarkdownDriveCore

final class OAuthErrorClassifierTests: XCTestCase {
    func testClassifiesKnownInvalidRequestDescriptionsWithoutReturningRawText() {
        let cases = [
            ("Missing required parameter: client_secret", "invalid_request/client_secret_rejected"),
            ("Invalid redirect_uri", "invalid_request/redirect_uri_rejected"),
            ("Invalid code_verifier", "invalid_request/pkce_rejected"),
            ("Missing grant_type", "invalid_request/grant_type_rejected"),
            ("Invalid client_id", "invalid_request/client_id_rejected"),
            ("Missing required parameter: code", "invalid_request/authorization_code_rejected"),
        ]

        for (description, expected) in cases {
            XCTAssertEqual(
                OAuthErrorClassifier.safeCode(
                    code: "invalid_request",
                    description: description,
                    statusCode: 400
                ),
                expected
            )
        }
    }

    func testDoesNotExposeUnknownServerDescription() {
        XCTAssertEqual(
            OAuthErrorClassifier.safeCode(
                code: "invalid_request",
                description: "Unexpected response containing user data",
                statusCode: 400
            ),
            "invalid_request"
        )
    }

    func testDoesNotExposeUnknownErrorCode() {
        XCTAssertEqual(
            OAuthErrorClassifier.safeCode(
                code: "server_supplied_detail",
                description: nil,
                statusCode: 418
            ),
            "HTTP_418"
        )
    }
}
