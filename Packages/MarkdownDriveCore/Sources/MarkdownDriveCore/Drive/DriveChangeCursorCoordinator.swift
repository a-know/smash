public struct PreparedDriveChangeCursor: Equatable, Sendable {
    public let scope: DriveChangeCursorScope
    public let cursor: DriveChangeCursor
    public let requiresPersistence: Bool

    public init(
        scope: DriveChangeCursorScope,
        cursor: DriveChangeCursor,
        requiresPersistence: Bool
    ) {
        self.scope = scope
        self.cursor = cursor
        self.requiresPersistence = requiresPersistence
    }
}

public actor DriveChangeCursorCoordinator {
    private let accountClient: any DriveAccountClient
    private let changeClient: any DriveChangeClient
    private let cursorStore: any DriveChangeCursorStore

    public init(
        accountClient: any DriveAccountClient,
        changeClient: any DriveChangeClient,
        cursorStore: any DriveChangeCursorStore
    ) {
        self.accountClient = accountClient
        self.changeClient = changeClient
        self.cursorStore = cursorStore
    }

    public func prepare(vaultRootFolderID: String) async throws -> PreparedDriveChangeCursor {
        let accountID = try await accountClient.getCurrentAccountID()
        let scope = DriveChangeCursorScope(
            accountID: accountID,
            vaultRootFolderID: vaultRootFolderID
        )
        if let cursor = try await cursorStore.loadCursor(for: scope) {
            return PreparedDriveChangeCursor(
                scope: scope,
                cursor: cursor,
                requiresPersistence: false
            )
        }

        let cursor = try await changeClient.getStartChangeCursor()
        return PreparedDriveChangeCursor(
            scope: scope,
            cursor: cursor,
            requiresPersistence: true
        )
    }

    public func commit(_ preparedCursor: PreparedDriveChangeCursor) async throws {
        guard preparedCursor.requiresPersistence else {
            return
        }
        try await cursorStore.saveCursor(
            preparedCursor.cursor,
            for: preparedCursor.scope
        )
    }
}
