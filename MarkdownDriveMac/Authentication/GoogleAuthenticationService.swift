import Foundation
import MarkdownDriveCore

actor GoogleAuthenticationService: AuthenticationService {
    private let authorizationFlow: GoogleOAuthAuthorizationFlow
    private let tokenClient: GoogleOAuthTokenClient
    private let refreshTokenStore: any RefreshTokenStore

    private var currentAccessCredential: AccessCredential?
    private var currentRefreshToken: String?

    init(
        authorizationFlow: GoogleOAuthAuthorizationFlow = GoogleOAuthAuthorizationFlow(),
        tokenClient: GoogleOAuthTokenClient = GoogleOAuthTokenClient(),
        refreshTokenStore: any RefreshTokenStore = KeychainRefreshTokenStore()
    ) {
        self.authorizationFlow = authorizationFlow
        self.tokenClient = tokenClient
        self.refreshTokenStore = refreshTokenStore
    }

    func restoreSession() async throws -> AuthenticatedSession? {
        guard let refreshToken = try refreshTokenStore.load() else {
            return nil
        }
        currentRefreshToken = refreshToken

        do {
            return try await refreshSession(using: refreshToken)
        } catch AuthenticationError.reauthenticationRequired {
            currentRefreshToken = nil
            try refreshTokenStore.remove()
            throw AuthenticationError.reauthenticationRequired
        }
    }

    func signIn() async throws -> AuthenticatedSession {
        let configuration = try GoogleOAuthConfiguration.load()
        let grant = try await authorizationFlow.authorize(configuration: configuration)
        let tokenResponse = try await tokenClient.exchangeAuthorizationCode(
            grant.code,
            codeVerifier: grant.codeVerifier,
            redirectURI: grant.redirectURI,
            configuration: configuration
        )

        guard let refreshToken = tokenResponse.refreshToken, !refreshToken.isEmpty else {
            throw AuthenticationError.oauthServerRejected(code: "missing_refresh_token")
        }

        do {
            try refreshTokenStore.save(refreshToken)
            currentRefreshToken = refreshToken
        } catch {
            await tokenClient.revoke(refreshToken)
            throw error
        }

        return try updateCurrentCredential(from: tokenResponse)
    }

    func signOut() async throws {
        let refreshToken = try currentRefreshToken ?? refreshTokenStore.load()
        currentAccessCredential = nil
        currentRefreshToken = nil
        try refreshTokenStore.remove()

        if let refreshToken {
            await tokenClient.revoke(refreshToken)
        }
    }

    func validAccessToken() async throws -> AccessToken {
        if let currentAccessCredential,
            currentAccessCredential.expiresAt > Date().addingTimeInterval(60)
        {
            return currentAccessCredential.accessToken
        }

        let refreshToken = try currentRefreshToken ?? refreshTokenStore.load()
        guard let refreshToken else {
            throw AuthenticationError.reauthenticationRequired
        }
        currentRefreshToken = refreshToken

        do {
            _ = try await refreshSession(using: refreshToken)
            guard let currentAccessCredential else {
                throw AuthenticationError.unexpected
            }
            return currentAccessCredential.accessToken
        } catch AuthenticationError.reauthenticationRequired {
            currentAccessCredential = nil
            currentRefreshToken = nil
            try refreshTokenStore.remove()
            throw AuthenticationError.reauthenticationRequired
        }
    }

    private func refreshSession(using refreshToken: String) async throws -> AuthenticatedSession {
        let configuration = try GoogleOAuthConfiguration.load()
        let response = try await tokenClient.refreshAccessToken(
            refreshToken: refreshToken,
            configuration: configuration
        )

        if let rotatedRefreshToken = response.refreshToken, !rotatedRefreshToken.isEmpty {
            try refreshTokenStore.save(rotatedRefreshToken)
            currentRefreshToken = rotatedRefreshToken
        }

        return try updateCurrentCredential(from: response)
    }

    private func updateCurrentCredential(from response: GoogleTokenResponse) throws -> AuthenticatedSession {
        let grantedScopes = Set(response.scope?.split(separator: " ").map(String.init) ?? [])
        guard !response.accessToken.isEmpty,
            response.expiresIn > 0,
            grantedScopes.contains(GoogleOAuthConfiguration.driveScope)
        else {
            throw AuthenticationError.invalidAuthorizationResponse
        }

        let expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        currentAccessCredential = AccessCredential(
            accessToken: AccessToken(rawValue: response.accessToken),
            expiresAt: expiresAt
        )
        return AuthenticatedSession(accessTokenExpiresAt: expiresAt)
    }
}

private struct AccessCredential: Sendable {
    let accessToken: AccessToken
    let expiresAt: Date
}
