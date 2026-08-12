import Foundation

public enum AuthenticationError: Error, Equatable, Sendable {
    case authorizationCancelled
    case browserLaunchFailed
    case callbackListenerFailed
    case configurationMissing
    case clientSecretMissing
    case credentialStorageFailed
    case invalidAuthorizationResponse
    case networkFailure
    case oauthServerRejected(code: String)
    case reauthenticationRequired
    case tokenExchangeFailed
    case unexpected
}

extension AuthenticationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authorizationCancelled:
            "Google authorization was cancelled."
        case .browserLaunchFailed:
            "The Google authorization page could not be opened."
        case .callbackListenerFailed:
            "The local authorization callback could not be received."
        case .configurationMissing:
            "The Google OAuth client ID is not configured."
        case .clientSecretMissing:
            "The Google OAuth client secret is not configured."
        case .credentialStorageFailed:
            "The authentication credential could not be stored securely."
        case .invalidAuthorizationResponse:
            "Google returned an invalid authorization response."
        case .networkFailure:
            "Google could not be reached. Check your connection and try again."
        case .oauthServerRejected(let code):
            "Google rejected authentication (\(code))."
        case .reauthenticationRequired:
            "Your Google authorization is no longer valid. Sign in again."
        case .tokenExchangeFailed:
            "Google could not complete authentication."
        case .unexpected:
            "An unexpected authentication error occurred."
        }
    }
}
