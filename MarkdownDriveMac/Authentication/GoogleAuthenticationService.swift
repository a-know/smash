import Foundation
import MarkdownDriveCore

actor GoogleAuthenticationService: AuthenticationService {
    private let authorizationFlow: any GoogleOAuthAuthorizationFlowProtocol
    private let tokenClient: any GoogleOAuthTokenClientProtocol
    private let refreshTokenStore: any RefreshTokenStore
    private let configurationProvider: @Sendable () throws -> GoogleOAuthConfiguration

    private var currentAccessCredential: AccessCredential?
    private var currentRefreshToken: String?
    private var sessionGeneration: UInt64 = 0
    private var nextRefreshID: UInt64 = 0
    private var currentRefreshID: UInt64?
    private var refreshTask: Task<AuthenticatedSession, any Error>?

    init(
        authorizationFlow: any GoogleOAuthAuthorizationFlowProtocol = GoogleOAuthAuthorizationFlow(),
        tokenClient: any GoogleOAuthTokenClientProtocol = GoogleOAuthTokenClient(),
        refreshTokenStore: any RefreshTokenStore = KeychainRefreshTokenStore(),
        configurationProvider: @escaping @Sendable () throws -> GoogleOAuthConfiguration =
            GoogleOAuthConfiguration.load
    ) {
        self.authorizationFlow = authorizationFlow
        self.tokenClient = tokenClient
        self.refreshTokenStore = refreshTokenStore
        self.configurationProvider = configurationProvider
    }

    func restoreSession() async throws -> AuthenticatedSession? {
        let generation = beginSessionReplacement()
        guard let refreshToken = try refreshTokenStore.load() else {
            return nil
        }
        currentRefreshToken = refreshToken

        do {
            return try await refreshSession(using: refreshToken, generation: generation)
        } catch AuthenticationError.reauthenticationRequired {
            if sessionGeneration == generation {
                currentRefreshToken = nil
                try refreshTokenStore.remove()
            }
            throw AuthenticationError.reauthenticationRequired
        }
    }

    func signIn() async throws -> AuthenticatedSession {
        let generation = beginSessionReplacement()
        let configuration = try configurationProvider()
        let grant = try await authorizationFlow.authorize(configuration: configuration)
        try validateSessionGeneration(generation)
        let tokenResponse = try await tokenClient.exchangeAuthorizationCode(
            grant.code,
            codeVerifier: grant.codeVerifier,
            redirectURI: grant.redirectURI,
            configuration: configuration
        )
        guard sessionGeneration == generation else {
            await revoke(tokenResponse)
            throw AuthenticationError.reauthenticationRequired
        }

        guard let refreshToken = tokenResponse.refreshToken, !refreshToken.isEmpty else {
            throw AuthenticationError.oauthServerRejected(code: "missing_refresh_token")
        }

        invalidateCurrentSession()
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
        invalidateCurrentSession()
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
        let generation = sessionGeneration

        do {
            _ = try await refreshSession(
                using: refreshToken,
                generation: generation
            )
            guard let currentAccessCredential else {
                throw AuthenticationError.unexpected
            }
            return currentAccessCredential.accessToken
        } catch AuthenticationError.reauthenticationRequired {
            if sessionGeneration == generation {
                currentAccessCredential = nil
                currentRefreshToken = nil
                try refreshTokenStore.remove()
            }
            throw AuthenticationError.reauthenticationRequired
        }
    }

    func refreshAccessToken(afterRejected rejectedToken: AccessToken) async throws -> AccessToken {
        if let currentAccessCredential,
            currentAccessCredential.accessToken != rejectedToken,
            currentAccessCredential.expiresAt > Date().addingTimeInterval(60)
        {
            return currentAccessCredential.accessToken
        }

        currentAccessCredential = nil
        return try await validAccessToken()
    }

    private func refreshSession(
        using refreshToken: String,
        generation: UInt64
    ) async throws -> AuthenticatedSession {
        if let refreshTask,
            currentRefreshID != nil,
            generation == sessionGeneration
        {
            return try await refreshTask.value
        }

        let configuration = try configurationProvider()
        nextRefreshID &+= 1
        let refreshID = nextRefreshID
        currentRefreshID = refreshID
        let tokenClient = self.tokenClient
        let task = Task<AuthenticatedSession, any Error> {
            let response = try await tokenClient.refreshAccessToken(
                refreshToken: refreshToken,
                configuration: configuration
            )
            return try await self.commitRefresh(
                response,
                originalRefreshToken: refreshToken,
                generation: generation,
                refreshID: refreshID
            )
        }
        refreshTask = task

        do {
            let session = try await task.value
            clearRefreshTask(ifID: refreshID)
            return session
        } catch {
            clearRefreshTask(ifID: refreshID)
            throw error
        }
    }

    private func commitRefresh(
        _ response: GoogleTokenResponse,
        originalRefreshToken: String,
        generation: UInt64,
        refreshID: UInt64
    ) async throws -> AuthenticatedSession {
        guard sessionGeneration == generation,
            currentRefreshID == refreshID
        else {
            await tokenClient.revoke(response.refreshToken ?? originalRefreshToken)
            throw AuthenticationError.reauthenticationRequired
        }

        if let rotatedRefreshToken = response.refreshToken, !rotatedRefreshToken.isEmpty {
            try refreshTokenStore.save(rotatedRefreshToken)
            currentRefreshToken = rotatedRefreshToken
        }

        return try updateCurrentCredential(from: response)
    }

    private func beginSessionReplacement() -> UInt64 {
        invalidateCurrentSession()
        currentAccessCredential = nil
        currentRefreshToken = nil
        return sessionGeneration
    }

    private func invalidateCurrentSession() {
        sessionGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        currentRefreshID = nil
    }

    private func validateSessionGeneration(_ generation: UInt64) throws {
        guard sessionGeneration == generation else {
            throw AuthenticationError.reauthenticationRequired
        }
    }

    private func clearRefreshTask(ifID refreshID: UInt64) {
        guard currentRefreshID == refreshID else {
            return
        }
        refreshTask = nil
        currentRefreshID = nil
    }

    private func revoke(_ response: GoogleTokenResponse) async {
        await tokenClient.revoke(response.refreshToken ?? response.accessToken)
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
