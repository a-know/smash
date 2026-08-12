import Foundation

public struct AuthenticatedSession: Equatable, Sendable {
    public let accessTokenExpiresAt: Date

    public init(accessTokenExpiresAt: Date) {
        self.accessTokenExpiresAt = accessTokenExpiresAt
    }
}
