import Foundation
import MarkdownDriveCore
import XCTest

@testable import MarkdownDriveMac

final class UserDefaultsDriveChangeCursorStoreTests: XCTestCase {
    func testPersistsCursorsIndependentlyByAccountAndVault() async throws {
        let suiteName = "UserDefaultsDriveChangeCursorStoreTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsDriveChangeCursorStore(suiteName: suiteName)
        let accountOneVaultOne = scope(accountID: "account-1", vaultID: "vault-1")
        let accountOneVaultTwo = scope(accountID: "account-1", vaultID: "vault-2")
        let accountTwoVaultOne = scope(accountID: "account-2", vaultID: "vault-1")

        try await store.saveCursor(
            DriveChangeCursor(rawValue: "cursor-1-1"),
            for: accountOneVaultOne
        )
        try await store.saveCursor(
            DriveChangeCursor(rawValue: "cursor-1-2"),
            for: accountOneVaultTwo
        )
        try await store.saveCursor(
            DriveChangeCursor(rawValue: "cursor-2-1"),
            for: accountTwoVaultOne
        )

        let restoredStore = UserDefaultsDriveChangeCursorStore(suiteName: suiteName)
        let first = try await restoredStore.loadCursor(for: accountOneVaultOne)
        let second = try await restoredStore.loadCursor(for: accountOneVaultTwo)
        let third = try await restoredStore.loadCursor(for: accountTwoVaultOne)
        XCTAssertEqual(first, DriveChangeCursor(rawValue: "cursor-1-1"))
        XCTAssertEqual(second, DriveChangeCursor(rawValue: "cursor-1-2"))
        XCTAssertEqual(third, DriveChangeCursor(rawValue: "cursor-2-1"))
    }

    func testRemovingCursorPreservesOtherScopes() async throws {
        let suiteName = "UserDefaultsDriveChangeCursorStoreTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsDriveChangeCursorStore(suiteName: suiteName)
        let removedScope = scope(accountID: "account-1", vaultID: "vault-1")
        let preservedScope = scope(accountID: "account-1", vaultID: "vault-2")
        try await store.saveCursor(DriveChangeCursor(rawValue: "removed"), for: removedScope)
        try await store.saveCursor(DriveChangeCursor(rawValue: "preserved"), for: preservedScope)

        try await store.removeCursor(for: removedScope)

        let removed = try await store.loadCursor(for: removedScope)
        let preserved = try await store.loadCursor(for: preservedScope)
        XCTAssertNil(removed)
        XCTAssertEqual(preserved, DriveChangeCursor(rawValue: "preserved"))
    }

    func testCorruptSnapshotFailsWithoutReplacingIt() async throws {
        let suiteName = "UserDefaultsDriveChangeCursorStoreTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(Data("not-json".utf8), forKey: "driveChangeCursors")
        let store = UserDefaultsDriveChangeCursorStore(suiteName: suiteName)

        do {
            try await store.saveCursor(
                DriveChangeCursor(rawValue: "new"),
                for: scope(accountID: "account", vaultID: "vault")
            )
            XCTFail("Expected corrupt persistence to fail")
        } catch {
            XCTAssertEqual(defaults.data(forKey: "driveChangeCursors"), Data("not-json".utf8))
        }
    }

    private func scope(accountID: String, vaultID: String) -> DriveChangeCursorScope {
        DriveChangeCursorScope(
            accountID: DriveAccountID(rawValue: accountID),
            vaultRootFolderID: vaultID
        )
    }
}
