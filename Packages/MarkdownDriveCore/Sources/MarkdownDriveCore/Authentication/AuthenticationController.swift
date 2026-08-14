public actor AuthenticationController {
    public private(set) var state: AuthenticationState = .signedOut

    private let service: any AuthenticationService
    private var operationGeneration: UInt64 = 0

    public init(service: any AuthenticationService) {
        self.service = service
    }

    @discardableResult
    public func restoreSession() async -> AuthenticationState {
        let generation = beginOperation()
        state = .restoring

        do {
            if let session = try await service.restoreSession() {
                if operationGeneration == generation {
                    state = .signedIn(session)
                }
            } else {
                if operationGeneration == generation {
                    state = .signedOut
                }
            }
        } catch {
            if operationGeneration == generation {
                state = .failed(Self.authenticationError(from: error))
            }
        }

        return state
    }

    @discardableResult
    public func signIn() async -> AuthenticationState {
        let generation = beginOperation()
        state = .signingIn

        do {
            let session = try await service.signIn()
            if operationGeneration == generation {
                state = .signedIn(session)
            }
        } catch {
            if operationGeneration == generation {
                state = .failed(Self.authenticationError(from: error))
            }
        }

        return state
    }

    @discardableResult
    public func signOut() async -> AuthenticationState {
        let generation = beginOperation()
        do {
            try await service.signOut()
            if operationGeneration == generation {
                state = .signedOut
            }
        } catch {
            if operationGeneration == generation {
                state = .failed(Self.authenticationError(from: error))
            }
        }

        return state
    }

    public func validAccessToken() async throws -> AccessToken {
        let generation = operationGeneration
        do {
            return try await service.validAccessToken()
        } catch AuthenticationError.reauthenticationRequired {
            if operationGeneration == generation {
                state = .failed(.reauthenticationRequired)
            }
            throw AuthenticationError.reauthenticationRequired
        }
    }

    public func refreshAccessToken(afterRejected rejectedToken: AccessToken) async throws -> AccessToken {
        let generation = operationGeneration
        do {
            return try await service.refreshAccessToken(afterRejected: rejectedToken)
        } catch AuthenticationError.reauthenticationRequired {
            if operationGeneration == generation {
                state = .failed(.reauthenticationRequired)
            }
            throw AuthenticationError.reauthenticationRequired
        }
    }

    private static func authenticationError(from error: any Error) -> AuthenticationError {
        error as? AuthenticationError ?? .unexpected
    }

    private func beginOperation() -> UInt64 {
        operationGeneration &+= 1
        return operationGeneration
    }
}
