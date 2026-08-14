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
    private var navigationGeneration: UInt64 = 0

    public init(driveClient: any DriveClient) {
        self.driveClient = driveClient
    }

    public func loadMyDrive() async throws -> DriveFolderBrowserSnapshot {
        let generation = beginNavigation()
        let root = try await driveClient.getItem(id: Self.myDriveRootID)
        guard root.kind == .folder else {
            throw DriveError.itemIsNotFolder
        }
        let loadedChildFolders = try await loadChildFolders(of: root.id)
        try validateNavigation(generation)
        path = [root]
        childFolders = loadedChildFolders
        return snapshot
    }

    public func openFolder(id: String) async throws -> DriveFolderBrowserSnapshot {
        guard let folder = childFolders.first(where: { $0.id == id }) else {
            throw DriveError.browserBoundaryViolation
        }
        let expectedPath = path
        let generation = beginNavigation()
        let loadedChildFolders = try await loadChildFolders(of: folder.id)
        try validateNavigation(generation, expectedPath: expectedPath)
        path = expectedPath + [folder]
        childFolders = loadedChildFolders
        return snapshot
    }

    public func navigateBack() async throws -> DriveFolderBrowserSnapshot {
        let generation = beginNavigation()
        guard path.count > 1 else {
            return snapshot
        }
        let expectedPath = path
        let destinationPath = Array(expectedPath.dropLast())
        let loadedChildFolders = try await loadChildFolders(of: destinationPath[destinationPath.count - 1].id)
        try validateNavigation(generation, expectedPath: expectedPath)
        path = destinationPath
        childFolders = loadedChildFolders
        return snapshot
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

    private func beginNavigation() -> UInt64 {
        navigationGeneration &+= 1
        return navigationGeneration
    }

    private func validateNavigation(
        _ generation: UInt64,
        expectedPath: [DriveItem]? = nil
    ) throws {
        guard navigationGeneration == generation,
            expectedPath == nil || path == expectedPath
        else {
            throw CancellationError()
        }
    }

    private var snapshot: DriveFolderBrowserSnapshot {
        DriveFolderBrowserSnapshot(path: path, childFolders: childFolders)
    }
}
