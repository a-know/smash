import XCTest

@testable import MarkdownDriveCore

final class DriveFolderBrowserTests: XCTestCase {
    func testLoadsOnlyUntrashedFoldersInNaturalNameOrder() async throws {
        let root = folder(id: "root", name: "My Drive")
        let client = FakeDriveClient(
            items: ["root": root],
            children: [
                "root": [
                    folder(id: "folder-10", name: "Folder 10"),
                    DriveItem(id: "note", name: "note.md", kind: .file),
                    folder(id: "trash", name: "Trash", isTrashed: true),
                    folder(id: "folder-2", name: "Folder 2"),
                ]
            ]
        )
        let browser = DriveFolderBrowser(driveClient: client)

        let snapshot = try await browser.loadMyDrive()

        XCTAssertEqual(snapshot.path, [root])
        XCTAssertEqual(snapshot.childFolders.map(\.id), ["folder-2", "folder-10"])
        XCTAssertFalse(snapshot.canNavigateBack)
    }

    func testOpensVisibleChildAndNavigatesBack() async throws {
        let root = folder(id: "root", name: "My Drive")
        let work = folder(id: "work", name: "Work")
        let client = FakeDriveClient(
            items: ["root": root],
            children: [
                "root": [work],
                "work": [folder(id: "projects", name: "Projects")],
            ]
        )
        let browser = DriveFolderBrowser(driveClient: client)
        _ = try await browser.loadMyDrive()

        let opened = try await browser.openFolder(id: "work")
        let vault = try await browser.makeVault()
        let returned = try await browser.navigateBack()

        XCTAssertEqual(opened.path, [root, work])
        XCTAssertEqual(opened.childFolders.map(\.id), ["projects"])
        XCTAssertEqual(vault, Vault(rootFolderID: "work", displayName: "Work"))
        XCTAssertEqual(returned.path, [root])
    }

    func testRejectsOpeningArbitraryFolderID() async throws {
        let root = folder(id: "root", name: "My Drive")
        let browser = DriveFolderBrowser(
            driveClient: FakeDriveClient(items: ["root": root], children: ["root": []])
        )
        _ = try await browser.loadMyDrive()

        do {
            _ = try await browser.openFolder(id: "unrelated-folder")
            XCTFail("Expected browser boundary violation")
        } catch {
            XCTAssertEqual(error as? DriveError, .browserBoundaryViolation)
        }
    }

    func testFailedOpenKeepsCurrentPath() async throws {
        let root = folder(id: "root", name: "My Drive")
        let work = folder(id: "work", name: "Work")
        let client = FakeDriveClient(
            items: ["root": root],
            children: ["root": [work]],
            failingFolderIDs: ["work"]
        )
        let browser = DriveFolderBrowser(driveClient: client)
        _ = try await browser.loadMyDrive()

        do {
            _ = try await browser.openFolder(id: "work")
            XCTFail("Expected child listing to fail")
        } catch {
            XCTAssertEqual(error as? DriveError, .networkFailure)
        }

        let vault = try await browser.makeVault()
        XCTAssertEqual(vault.rootFolderID, "root")
    }

    func testReloadSupersedesAnInFlightFolderOpen() async throws {
        let root = folder(id: "root", name: "My Drive")
        let work = folder(id: "work", name: "Work")
        let client = FakeDriveClient(
            items: ["root": root],
            children: ["root": [work], "work": []],
            delays: ["work": 100_000_000]
        )
        let browser = DriveFolderBrowser(driveClient: client)
        _ = try await browser.loadMyDrive()

        let opening = Task {
            try await browser.openFolder(id: "work")
        }
        await client.waitUntilListChildrenStarts(folderID: "work")
        let reloaded = try await browser.loadMyDrive()

        do {
            _ = try await opening.value
            XCTFail("Expected the stale folder open to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let vault = try await browser.makeVault()
        XCTAssertEqual(reloaded.path, [root])
        XCTAssertEqual(vault.rootFolderID, "root")
    }

    func testBackAtRootSupersedesAnInFlightFolderOpen() async throws {
        let root = folder(id: "root", name: "My Drive")
        let work = folder(id: "work", name: "Work")
        let client = FakeDriveClient(
            items: ["root": root],
            children: ["root": [work], "work": []],
            delays: ["work": 100_000_000]
        )
        let browser = DriveFolderBrowser(driveClient: client)
        _ = try await browser.loadMyDrive()

        let opening = Task {
            try await browser.openFolder(id: "work")
        }
        await client.waitUntilListChildrenStarts(folderID: "work")
        let returned = try await browser.navigateBack()

        do {
            _ = try await opening.value
            XCTFail("Expected the stale folder open to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let vault = try await browser.makeVault()
        XCTAssertEqual(returned.path, [root])
        XCTAssertEqual(vault.rootFolderID, "root")
    }

    private func folder(
        id: String,
        name: String,
        isTrashed: Bool = false
    ) -> DriveItem {
        DriveItem(
            id: id,
            name: name,
            kind: .folder,
            mimeType: GoogleDriveAPIClient.folderMimeType,
            isTrashed: isTrashed
        )
    }
}

private actor FakeDriveClient: DriveClient {
    private let items: [String: DriveItem]
    private let children: [String: [DriveItem]]
    private let failingFolderIDs: Set<String>
    private let delays: [String: UInt64]
    private var startedFolderIDs: Set<String> = []

    init(
        items: [String: DriveItem],
        children: [String: [DriveItem]],
        failingFolderIDs: Set<String> = [],
        delays: [String: UInt64] = [:]
    ) {
        self.items = items
        self.children = children
        self.failingFolderIDs = failingFolderIDs
        self.delays = delays
    }

    func getItem(id: String) async throws -> DriveItem {
        guard let item = items[id] else {
            throw DriveError.itemNotFound
        }
        return item
    }

    func listChildren(of folderID: String) async throws -> [DriveItem] {
        startedFolderIDs.insert(folderID)
        if let delay = delays[folderID] {
            try await Task.sleep(nanoseconds: delay)
        }
        if failingFolderIDs.contains(folderID) {
            throw DriveError.networkFailure
        }
        return children[folderID] ?? []
    }

    func waitUntilListChildrenStarts(folderID: String) async {
        while !startedFolderIDs.contains(folderID) {
            await Task.yield()
        }
    }
}
