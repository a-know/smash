public protocol AuthenticationService: Sendable {
    func restoreSession() async throws -> AuthenticatedSession?
    func signIn() async throws -> AuthenticatedSession
    func signOut() async throws
    func validAccessToken() async throws -> AccessToken
}
