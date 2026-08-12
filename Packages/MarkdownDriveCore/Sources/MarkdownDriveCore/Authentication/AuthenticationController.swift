public actor AuthenticationController {
    public private(set) var state: AuthenticationState = .signedOut

    private let service: any AuthenticationService

    public init(service: any AuthenticationService) {
        self.service = service
    }

    @discardableResult
    public func restoreSession() async -> AuthenticationState {
        state = .restoring

        do {
            if let session = try await service.restoreSession() {
                state = .signedIn(session)
            } else {
                state = .signedOut
            }
        } catch {
            state = .failed(Self.authenticationError(from: error))
        }

        return state
    }

    @discardableResult
    public func signIn() async -> AuthenticationState {
        state = .signingIn

        do {
            state = .signedIn(try await service.signIn())
        } catch {
            state = .failed(Self.authenticationError(from: error))
        }

        return state
    }

    @discardableResult
    public func signOut() async -> AuthenticationState {
        do {
            try await service.signOut()
            state = .signedOut
        } catch {
            state = .failed(Self.authenticationError(from: error))
        }

        return state
    }

    public func validAccessToken() async throws -> AccessToken {
        do {
            return try await service.validAccessToken()
        } catch AuthenticationError.reauthenticationRequired {
            state = .failed(.reauthenticationRequired)
            throw AuthenticationError.reauthenticationRequired
        }
    }

    private static func authenticationError(from error: any Error) -> AuthenticationError {
        error as? AuthenticationError ?? .unexpected
    }
}
