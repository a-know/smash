public enum DriveError: Error, Equatable, Sendable {
    case authenticationRequired
    case incompleteSearch
    case invalidResponse
    case itemNotFound
    case networkFailure
    case permissionDenied
    case rateLimited
    case serverUnavailable
    case unexpectedStatus(Int)
}
