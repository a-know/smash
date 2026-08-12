public enum AuthenticationState: Equatable, Sendable {
    case signedOut
    case restoring
    case signingIn
    case signedIn(AuthenticatedSession)
    case failed(AuthenticationError)
}
