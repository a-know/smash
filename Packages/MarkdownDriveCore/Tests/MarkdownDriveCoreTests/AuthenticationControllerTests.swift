import Foundation
import XCTest

@testable import MarkdownDriveCore

final class AuthenticationControllerTests: XCTestCase {
    func testOAuthFormEncoderEscapesFormControlCharacters() throws {
        let data = try OAuthFormEncoder.encode([
            URLQueryItem(name: "code", value: "4/abc+def=ghi"),
            URLQueryItem(name: "client_secret", value: "secret+value/part="),
            URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:54321/oauth2callback"),
        ])

        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "code=4%2Fabc%2Bdef%3Dghi&client_secret=secret%2Bvalue%2Fpart%3D&redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2Foauth2callback"
        )
    }

    func testRestoreWithoutStoredCredentialEndsSignedOut() async {
        let service = FakeAuthenticationService(restoredSession: nil)
        let controller = AuthenticationController(service: service)

        let state = await controller.restoreSession()

        XCTAssertEqual(state, .signedOut)
    }

    func testRestoreWithStoredCredentialEndsSignedIn() async {
        let session = AuthenticatedSession(accessTokenExpiresAt: Date(timeIntervalSince1970: 1_000))
        let service = FakeAuthenticationService(restoredSession: session)
        let controller = AuthenticationController(service: service)

        let state = await controller.restoreSession()

        XCTAssertEqual(state, .signedIn(session))
    }

    func testSignInFailurePreservesTypedError() async {
        let service = FakeAuthenticationService(signInError: .authorizationCancelled)
        let controller = AuthenticationController(service: service)

        let state = await controller.signIn()

        XCTAssertEqual(state, .failed(.authorizationCancelled))
    }

    func testOAuthServerErrorPreservesOnlySafeErrorCode() async {
        let service = FakeAuthenticationService(
            signInError: .oauthServerRejected(code: "invalid_client")
        )
        let controller = AuthenticationController(service: service)

        let state = await controller.signIn()

        XCTAssertEqual(state, .failed(.oauthServerRejected(code: "invalid_client")))
    }

    func testRefreshFailureRequiresReauthentication() async {
        let service = FakeAuthenticationService(accessTokenError: .reauthenticationRequired)
        let controller = AuthenticationController(service: service)

        do {
            _ = try await controller.validAccessToken()
            XCTFail("Expected access token refresh to fail")
        } catch {
            XCTAssertEqual(error as? AuthenticationError, .reauthenticationRequired)
        }
        let state = await controller.state
        XCTAssertEqual(state, .failed(.reauthenticationRequired))
    }

    func testSignOutClearsAuthenticatedState() async {
        let session = AuthenticatedSession(accessTokenExpiresAt: Date(timeIntervalSince1970: 1_000))
        let service = FakeAuthenticationService(signInSession: session)
        let controller = AuthenticationController(service: service)
        _ = await controller.signIn()

        let state = await controller.signOut()

        XCTAssertEqual(state, .signedOut)
        let didSignOut = await service.didSignOut
        XCTAssertTrue(didSignOut)
    }
}

private actor FakeAuthenticationService: AuthenticationService {
    private let restoredSession: AuthenticatedSession?
    private let signInSession: AuthenticatedSession
    private let signInError: AuthenticationError?
    private let accessTokenError: AuthenticationError?

    private(set) var didSignOut = false

    init(
        restoredSession: AuthenticatedSession? = nil,
        signInSession: AuthenticatedSession = AuthenticatedSession(accessTokenExpiresAt: .distantFuture),
        signInError: AuthenticationError? = nil,
        accessTokenError: AuthenticationError? = nil
    ) {
        self.restoredSession = restoredSession
        self.signInSession = signInSession
        self.signInError = signInError
        self.accessTokenError = accessTokenError
    }

    func restoreSession() async throws -> AuthenticatedSession? {
        restoredSession
    }

    func signIn() async throws -> AuthenticatedSession {
        if let signInError {
            throw signInError
        }
        return signInSession
    }

    func signOut() async throws {
        didSignOut = true
    }

    func validAccessToken() async throws -> AccessToken {
        if let accessTokenError {
            throw accessTokenError
        }
        return AccessToken(rawValue: "fake-access-token")
    }
}
