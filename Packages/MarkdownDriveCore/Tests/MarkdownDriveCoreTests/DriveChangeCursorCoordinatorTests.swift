import MarkdownDriveCore
import XCTest

final class DriveChangeCursorCoordinatorTests: XCTestCase {
    func testPrepareReusesPersistedCursorWithoutRequestingStartCursor() async throws {
        let scope = DriveChangeCursorScope(
            accountID: DriveAccountID(rawValue: "account"),
            vaultRootFolderID: "vault"
        )
        let store = FakeCursorStore(cursors: [scope: DriveChangeCursor(rawValue: "persisted")])
        let client = FakeChangeIdentityClient(startCursor: DriveChangeCursor(rawValue: "new"))
        let coordinator = DriveChangeCursorCoordinator(
            accountClient: client,
            changeClient: client,
            cursorStore: store
        )

        let prepared = try await coordinator.prepare(vaultRootFolderID: "vault")

        XCTAssertEqual(prepared.scope, scope)
        XCTAssertEqual(prepared.cursor, DriveChangeCursor(rawValue: "persisted"))
        XCTAssertFalse(prepared.requiresPersistence)
        let requestCount = await client.startCursorRequestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testCommitPersistsNewCursorOnlyAfterPreparation() async throws {
        let store = FakeCursorStore()
        let client = FakeChangeIdentityClient(startCursor: DriveChangeCursor(rawValue: "start"))
        let coordinator = DriveChangeCursorCoordinator(
            accountClient: client,
            changeClient: client,
            cursorStore: store
        )

        let prepared = try await coordinator.prepare(vaultRootFolderID: "vault")

        XCTAssertTrue(prepared.requiresPersistence)
        var storedCursor = await store.cursor(for: prepared.scope)
        XCTAssertNil(storedCursor)

        try await coordinator.commit(prepared)

        storedCursor = await store.cursor(for: prepared.scope)
        XCTAssertEqual(storedCursor, DriveChangeCursor(rawValue: "start"))
    }

    func testCommitDoesNotRewritePersistedCursor() async throws {
        let scope = DriveChangeCursorScope(
            accountID: DriveAccountID(rawValue: "account"),
            vaultRootFolderID: "vault"
        )
        let store = FakeCursorStore(cursors: [scope: DriveChangeCursor(rawValue: "persisted")])
        let client = FakeChangeIdentityClient(startCursor: DriveChangeCursor(rawValue: "new"))
        let coordinator = DriveChangeCursorCoordinator(
            accountClient: client,
            changeClient: client,
            cursorStore: store
        )
        let prepared = try await coordinator.prepare(vaultRootFolderID: "vault")

        try await coordinator.commit(prepared)

        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 0)
    }
}

private actor FakeChangeIdentityClient: DriveAccountClient, DriveChangeClient {
    private let startCursor: DriveChangeCursor
    private(set) var startCursorRequestCount = 0

    init(startCursor: DriveChangeCursor) {
        self.startCursor = startCursor
    }

    func getCurrentAccountID() async throws -> DriveAccountID {
        DriveAccountID(rawValue: "account")
    }

    func getStartChangeCursor() async throws -> DriveChangeCursor {
        startCursorRequestCount += 1
        return startCursor
    }

    func listChanges(since cursor: DriveChangeCursor) async throws -> DriveChangeBatch {
        DriveChangeBatch(changes: [], newCursor: cursor)
    }
}

private actor FakeCursorStore: DriveChangeCursorStore {
    private var cursors: [DriveChangeCursorScope: DriveChangeCursor]
    private(set) var saveCount = 0

    init(cursors: [DriveChangeCursorScope: DriveChangeCursor] = [:]) {
        self.cursors = cursors
    }

    func loadCursor(for scope: DriveChangeCursorScope) async throws -> DriveChangeCursor? {
        cursors[scope]
    }

    func saveCursor(
        _ cursor: DriveChangeCursor,
        for scope: DriveChangeCursorScope
    ) async throws {
        saveCount += 1
        cursors[scope] = cursor
    }

    func removeCursor(for scope: DriveChangeCursorScope) async throws {
        cursors[scope] = nil
    }

    func cursor(for scope: DriveChangeCursorScope) -> DriveChangeCursor? {
        cursors[scope]
    }
}
