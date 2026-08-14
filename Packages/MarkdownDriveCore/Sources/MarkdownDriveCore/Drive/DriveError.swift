import Foundation

public enum DriveError: Error, Equatable, Sendable {
    case authenticationRequired
    case browserBoundaryViolation
    case downloadNotAllowed
    case fileChangedDuringDownload
    case incompleteSearch
    case invalidHierarchy
    case invalidName
    case invalidResponse
    case invalidUTF8
    case itemIsNotFolder
    case itemIsNotFile
    case itemNotFound
    case modificationNotAllowed
    case networkFailure
    case permissionDenied
    case rateLimited
    case serverUnavailable
    case unexpectedStatus(Int)
    case vaultBoundaryViolation
    case writeStatusUnknown
}

extension DriveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "Google Drive authentication is required."
        case .browserBoundaryViolation:
            "That folder is outside the current browser location."
        case .downloadNotAllowed:
            "Google Drive does not allow this file to be downloaded."
        case .fileChangedDuringDownload:
            "The file changed in Google Drive while it was being opened. Try again."
        case .incompleteSearch:
            "Google Drive returned an incomplete folder listing."
        case .invalidHierarchy:
            "The Vault contains an invalid folder hierarchy."
        case .invalidName:
            "Enter a non-empty name other than '.' or '..', without slashes or control characters."
        case .invalidResponse:
            "Google Drive returned an invalid response."
        case .invalidUTF8:
            "The Markdown file is not valid UTF-8 text."
        case .itemIsNotFolder:
            "The selected Google Drive item is not a folder."
        case .itemIsNotFile:
            "The selected Google Drive item is not a file."
        case .itemNotFound:
            "The Google Drive item could not be found."
        case .modificationNotAllowed:
            "Google Drive does not allow this file to be modified."
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
        case .vaultBoundaryViolation:
            "That file is outside the selected Vault."
        case .writeStatusUnknown:
            "Google Drive may have received the write, but its result could not be confirmed."
        }
    }
}
