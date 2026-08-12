import Foundation

public enum DriveError: Error, Equatable, Sendable {
    case authenticationRequired
    case browserBoundaryViolation
    case incompleteSearch
    case invalidResponse
    case itemIsNotFolder
    case itemNotFound
    case networkFailure
    case permissionDenied
    case rateLimited
    case serverUnavailable
    case unexpectedStatus(Int)
}

extension DriveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "Google Drive authentication is required."
        case .browserBoundaryViolation:
            "That folder is outside the current browser location."
        case .incompleteSearch:
            "Google Drive returned an incomplete folder listing."
        case .invalidResponse:
            "Google Drive returned an invalid response."
        case .itemIsNotFolder:
            "The selected Google Drive item is not a folder."
        case .itemNotFound:
            "The Google Drive item could not be found."
        case .networkFailure:
            "Google Drive could not be reached."
        case .permissionDenied:
            "Google Drive denied access to this item."
        case .rateLimited:
            "Google Drive is temporarily receiving too many requests."
        case .serverUnavailable:
            "Google Drive is temporarily unavailable."
        case .unexpectedStatus(let statusCode):
            "Google Drive returned HTTP status \(statusCode)."
        }
    }
}
