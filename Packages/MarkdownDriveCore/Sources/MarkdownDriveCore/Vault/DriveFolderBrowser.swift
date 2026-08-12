import Foundation

public struct DriveFolderBrowserSnapshot: Equatable, Sendable {
    public let path: [DriveItem]
    public let childFolders: [DriveItem]

    public init(path: [DriveItem], childFolders: [DriveItem]) {
        self.path = path
        self.childFolders = childFolders
    }

    public var currentFolder: DriveItem? {
        path.last
    }

    public var canNavigateBack: Bool {
        path.count > 1
    }
}

public actor DriveFolderBrowser {
    public static let myDriveRootID = "root"

    private let driveClient: any DriveClient
    private var path: [DriveItem] = []
    private var childFolders: [DriveItem] = []

    public init(driveClient: any DriveClient) {
        self.driveClient = driveClient
    }

    public func loadMyDrive() async throws -> DriveFolderBrowserSnapshot {
        let root = try await driveClient.getItem(id: Self.myDriveRootID)
        guard root.kind == .folder else {
            throw DriveError.itemIsNotFolder
        }
        path = [root]
        childFolders = try await loadChildFolders(of: root.id)
        return snapshot
    }

    public func openFolder(id: String) async throws -> DriveFolderBrowserSnapshot {
        guard let folder = childFolders.first(where: { $0.id == id }) else {
            throw DriveError.browserBoundaryViolation
        }
        path.append(folder)
        do {
            childFolders = try await loadChildFolders(of: folder.id)
            return snapshot
        } catch {
            path.removeLast()
            throw error
        }
    }

    public func navigateBack() async throws -> DriveFolderBrowserSnapshot {
        guard path.count > 1 else {
            return snapshot
        }
        let previousPath = path
        path.removeLast()
        do {
            childFolders = try await loadChildFolders(of: path[path.count - 1].id)
            return snapshot
        } catch {
            path = previousPath
            throw error
        }
    }

    public func makeVault() throws -> Vault {
        guard let folder = path.last else {
            throw DriveError.invalidResponse
        }
        return Vault(rootFolderID: folder.id, displayName: folder.name)
    }

    private func loadChildFolders(of folderID: String) async throws -> [DriveItem] {
        try await driveClient.listChildren(of: folderID)
            .filter { $0.kind == .folder && !$0.isTrashed }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private var snapshot: DriveFolderBrowserSnapshot {
        DriveFolderBrowserSnapshot(path: path, childFolders: childFolders)
    }
}
