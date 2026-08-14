import Foundation
import MarkdownDriveCore
import XCTest

@testable import MarkdownDriveMac

final class GoogleAuthenticationServiceTests: XCTestCase {
    func testConcurrentAccessTokenRequestsShareOneRefresh() async throws {
        let tokenClient = ControlledTokenClient()
        let tokenStore = FakeRefreshTokenStore(token: "refresh-1")
        let service = makeService(tokenClient: tokenClient, tokenStore: tokenStore)

        let firstRequest = Task {
            try await service.validAccessToken()
        }
        await tokenClient.waitForRefreshCount(1)
        let secondRequest = Task {
            try await service.validAccessToken()
        }
        await Task.yield()

        let refreshCountWhilePending = await tokenClient.refreshCount
        XCTAssertEqual(refreshCountWhilePending, 1)
        await tokenClient.completeNextRefresh(
            with: .success(tokenResponse(refreshToken: "refresh-2"))
        )

        let firstToken = try await firstRequest.value
        let secondToken = try await secondRequest.value
        XCTAssertEqual(firstToken, AccessToken(rawValue: "access-1"))
        XCTAssertEqual(secondToken, firstToken)
        XCTAssertEqual(tokenStore.savedTokens, ["refresh-2"])
        let completedRefreshCount = await tokenClient.refreshCount
        XCTAssertEqual(completedRefreshCount, 1)
    }

    func testSignOutInvalidatesInFlightRefreshWithoutRestoringSession() async throws {
        let tokenClient = ControlledTokenClient()
        let tokenStore = FakeRefreshTokenStore(token: "refresh-1")
        let service = makeService(tokenClient: tokenClient, tokenStore: tokenStore)

        let accessTokenRequest = Task {
            try await service.validAccessToken()
        }
        await tokenClient.waitForRefreshCount(1)

        try await service.signOut()
        await tokenClient.completeNextRefresh(
            with: .success(tokenResponse(refreshToken: "refresh-2"))
        )

        do {
            _ = try await accessTokenRequest.value
            XCTFail("Expected the invalidated refresh to fail")
        } catch {
            XCTAssertEqual(error as? AuthenticationError, .reauthenticationRequired)
        }
        XCTAssertNil(tokenStore.storedToken)
        XCTAssertTrue(tokenStore.savedTokens.isEmpty)
        let revokedTokens = await tokenClient.revokedTokens
        XCTAssertTrue(revokedTokens.contains("refresh-1"))
        XCTAssertTrue(revokedTokens.contains("refresh-2"))

        do {
            _ = try await service.validAccessToken()
            XCTFail("Expected the signed-out service to have no credential")
        } catch {
            XCTAssertEqual(error as? AuthenticationError, .reauthenticationRequired)
        }
    }

    func testStaleRefreshCannotClearCredentialsFromSubsequentSignIn() async throws {
        let signedInResponse = tokenResponse(
            accessToken: "new-access",
            refreshToken: "new-refresh"
        )
        let tokenClient = ControlledTokenClient(exchangeResponse: signedInResponse)
        let tokenStore = FakeRefreshTokenStore(token: "old-refresh")
        let service = makeService(tokenClient: tokenClient, tokenStore: tokenStore)

        let staleAccessTokenRequest = Task {
            try await service.validAccessToken()
        }
        await tokenClient.waitForRefreshCount(1)
        try await service.signOut()
        _ = try await service.signIn()

        await tokenClient.completeNextRefresh(
            with: .success(
                tokenResponse(
                    accessToken: "stale-access",
                    refreshToken: "stale-refresh"
                )
            )
        )

        do {
            _ = try await staleAccessTokenRequest.value
            XCTFail("Expected the stale refresh to be rejected")
        } catch {
            XCTAssertEqual(error as? AuthenticationError, .reauthenticationRequired)
        }
        XCTAssertEqual(tokenStore.storedToken, "new-refresh")
        let currentAccessToken = try await service.validAccessToken()
        XCTAssertEqual(currentAccessToken, AccessToken(rawValue: "new-access"))
    }

    func testRefreshStartedDuringInteractiveSignInCannotOverwriteNewSession() async throws {
        let authorizationFlow = ControlledAuthorizationFlow()
        let tokenClient = ControlledTokenClient(
            exchangeResponse: tokenResponse(
                accessToken: "new-access",
                refreshToken: "new-refresh"
            )
        )
        let tokenStore = FakeRefreshTokenStore(token: "old-refresh")
        let service = makeService(
            authorizationFlow: authorizationFlow,
            tokenClient: tokenClient,
            tokenStore: tokenStore
        )

        let signInRequest = Task {
            try await service.signIn()
        }
        await authorizationFlow.waitUntilAuthorizationStarts()
        let staleAccessTokenRequest = Task {
            try await service.validAccessToken()
        }
        await tokenClient.waitForRefreshCount(1)

        await authorizationFlow.completeAuthorization()
        _ = try await signInRequest.value
        await tokenClient.completeNextRefresh(
            with: .success(
                tokenResponse(
                    accessToken: "stale-access",
                    refreshToken: "stale-refresh"
                )
            )
        )

        do {
            _ = try await staleAccessTokenRequest.value
            XCTFail("Expected the refresh from the replaced session to fail")
        } catch {
            XCTAssertEqual(error as? AuthenticationError, .reauthenticationRequired)
        }
        XCTAssertEqual(tokenStore.storedToken, "new-refresh")
        let currentAccessToken = try await service.validAccessToken()
        XCTAssertEqual(currentAccessToken, AccessToken(rawValue: "new-access"))
    }

    private func makeService(
        authorizationFlow: any GoogleOAuthAuthorizationFlowProtocol = FakeAuthorizationFlow(),
        tokenClient: ControlledTokenClient,
        tokenStore: FakeRefreshTokenStore
    ) -> GoogleAuthenticationService {
        GoogleAuthenticationService(
            authorizationFlow: authorizationFlow,
            tokenClient: tokenClient,
            refreshTokenStore: tokenStore,
            configurationProvider: {
                GoogleOAuthConfiguration(
                    clientID: "client-id",
                    clientSecret: "client-secret",
                    scopes: [GoogleOAuthConfiguration.driveScope]
                )
            }
        )
    }

    private func tokenResponse(
        accessToken: String = "access-1",
        refreshToken: String?
    ) -> GoogleTokenResponse {
        GoogleTokenResponse(
            accessToken: accessToken,
            expiresIn: 3_600,
            refreshToken: refreshToken,
            scope: GoogleOAuthConfiguration.driveScope,
            tokenType: "Bearer"
        )
    }
}

private actor ControlledAuthorizationFlow: GoogleOAuthAuthorizationFlowProtocol {
    private var continuation: CheckedContinuation<GoogleAuthorizationGrant, Never>?
    private var didStartAuthorization = false

    func authorize(configuration: GoogleOAuthConfiguration) async throws -> GoogleAuthorizationGrant {
        didStartAuthorization = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilAuthorizationStarts() async {
        while !didStartAuthorization {
            await Task.yield()
        }
    }

    func completeAuthorization() {
        continuation?.resume(
            returning: GoogleAuthorizationGrant(
                code: "authorization-code",
                codeVerifier: "code-verifier",
                redirectURI: URL(string: "http://127.0.0.1/oauth2callback")!
            )
        )
        continuation = nil
    }
}

private struct FakeAuthorizationFlow: GoogleOAuthAuthorizationFlowProtocol {
    func authorize(configuration: GoogleOAuthConfiguration) async throws -> GoogleAuthorizationGrant {
        GoogleAuthorizationGrant(
            code: "authorization-code",
            codeVerifier: "code-verifier",
            redirectURI: URL(string: "http://127.0.0.1/oauth2callback")!
        )
    }
}

private actor ControlledTokenClient: GoogleOAuthTokenClientProtocol {
    private let exchangeResponse: GoogleTokenResponse?
    private var refreshContinuations: [CheckedContinuation<GoogleTokenResponse, any Error>] = []
    private(set) var refreshCount = 0
    private(set) var revokedTokens: [String] = []

    init(exchangeResponse: GoogleTokenResponse? = nil) {
        self.exchangeResponse = exchangeResponse
    }

    func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: URL,
        configuration: GoogleOAuthConfiguration
    ) async throws -> GoogleTokenResponse {
        guard let exchangeResponse else {
            throw AuthenticationError.unexpected
        }
        return exchangeResponse
    }

    func refreshAccessToken(
        refreshToken: String,
        configuration: GoogleOAuthConfiguration
    ) async throws -> GoogleTokenResponse {
        refreshCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            refreshContinuations.append(continuation)
        }
    }

    func revoke(_ token: String) async {
        revokedTokens.append(token)
    }

    func waitForRefreshCount(_ expectedCount: Int) async {
        while refreshCount < expectedCount {
            await Task.yield()
        }
    }

    func completeNextRefresh(with result: Result<GoogleTokenResponse, any Error>) {
        refreshContinuations.removeFirst().resume(with: result)
    }
}

private final class FakeRefreshTokenStore: RefreshTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var savedTokenValues: [String] = []

    init(token: String?) {
        self.token = token
    }

    var storedToken: String? {
        lock.withLock { token }
    }

    var savedTokens: [String] {
        lock.withLock { savedTokenValues }
    }

    func load() throws -> String? {
        lock.withLock { token }
    }

    func save(_ refreshToken: String) throws {
        lock.withLock {
            token = refreshToken
            savedTokenValues.append(refreshToken)
        }
    }

    func remove() throws {
        lock.withLock {
            token = nil
        }
    }
}
