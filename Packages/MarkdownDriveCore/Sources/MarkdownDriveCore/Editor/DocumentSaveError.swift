import Foundation

public enum DocumentSaveError: Error, Equatable, Sendable {
    case authentication(AuthenticationError)
    case conflict(remoteRevision: DriveFileRevision)
    case drive(DriveError)
    case remoteDeleted
    case unexpected
    case updateStatusUnknown
    case vaultBoundaryViolation
}

extension DocumentSaveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authentication(let error):
            error.localizedDescription
        case .conflict:
            "Remote changes were detected. Your local edits were not saved."
        case .drive(let error):
            error.localizedDescription
        case .remoteDeleted:
            "The file was deleted from Google Drive. Your local edits are still available."
        case .unexpected:
            "The document could not be saved. Your local edits are still available."
        case .updateStatusUnknown:
            "The connection ended during saving. Google Drive may have received the update; your local edits are still available."
        case .vaultBoundaryViolation:
            "The file is no longer inside the selected Vault. Your local edits were not saved."
        }
    }
}
