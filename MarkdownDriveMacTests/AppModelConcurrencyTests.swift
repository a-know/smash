import Foundation
import MarkdownDriveCore
import XCTest

@testable import MarkdownDriveMac

@MainActor
final class AppModelConcurrencyTests: XCTestCase {
    func testOlderVaultRefreshCannotOverwriteNewerTree() async throws {
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: [file(id: "initial", name: "initial.md")]),
                TreeResponse(
                    items: [file(id: "old", name: "old.md")],
                    delayNanoseconds: 100_000_000
                ),
                TreeResponse(items: [file(id: "new", name: "new.md")]),
            ]
        )
        let appModel = makeAppModel(driveClient: driveClient)
        await appModel.restoreSession()

        let olderRefresh = Task { @MainActor in
            await appModel.loadVaultTree()
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        await appModel.loadVaultTree()
        await olderRefresh.value

        guard case .loaded(let tree) = appModel.vaultTreeState else {
            return XCTFail("Expected the Vault tree to remain loaded")
        }
        XCTAssertNotNil(tree.markdownFile(id: "new"))
        XCTAssertNil(tree.markdownFile(id: "old"))
    }

    func testClearingSelectionInvalidatesInFlightDocumentLoad() async throws {
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: [file(id: "note", name: "note.md")])
            ],
            controlledDownload: DriveFileDownload(
                item: file(id: "note", name: "note.md"),
                data: Data("remote text".utf8),
                revision: revision()
            )
        )
        let appModel = makeAppModel(driveClient: driveClient)
        await appModel.restoreSession()

        let documentLoad = Task { @MainActor in
            await appModel.selectTreeItem(id: "note")
        }
        await driveClient.waitUntilDownloadStarts()
        await appModel.selectTreeItem(id: nil)
        await driveClient.completeDownload()
        await documentLoad.value

        XCTAssertEqual(appModel.selectedTreeItemID, nil)
        XCTAssertEqual(appModel.documentState, .idle)
    }

    func testSignOutInvalidatesInFlightVaultRestore() async throws {
        let driveClient = ControlledAppDriveClient(treeResponses: [])
        let vaultStore = ControlledAppVaultStore()
        let appModel = makeAppModel(
            driveClient: driveClient,
            vaultStore: vaultStore
        )

        let restoring = Task { @MainActor in
            await appModel.restoreSession()
        }
        await vaultStore.waitUntilLoadStarts()
        await appModel.signOut()
        await vaultStore.completeLoad(
            with: Vault(rootFolderID: "vault", displayName: "Vault")
        )
        await restoring.value

        XCTAssertEqual(appModel.authenticationState, .signedOut)
        XCTAssertNil(appModel.selectedVault)
        XCTAssertEqual(appModel.vaultTreeState, .idle)
    }

    func testReauthenticationInvalidatesDocumentLoadFromPreviousSession() async throws {
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: [file(id: "note", name: "note.md")]),
                TreeResponse(error: .authenticationRequired),
                TreeResponse(items: [file(id: "note", name: "note.md")]),
            ],
            controlledDownload: DriveFileDownload(
                item: file(id: "note", name: "note.md"),
                data: Data("old session content".utf8),
                revision: revision()
            )
        )
        let appModel = makeAppModel(driveClient: driveClient)
        await appModel.restoreSession()

        let oldSessionDocumentLoad = Task { @MainActor in
            await appModel.selectTreeItem(id: "note")
        }
        await driveClient.waitUntilDownloadStarts()
        await appModel.loadVaultTree()
        XCTAssertEqual(
            appModel.authenticationState,
            .failed(.reauthenticationRequired)
        )

        await appModel.signIn()
        await driveClient.completeDownload()
        await oldSessionDocumentLoad.value

        guard case .signedIn = appModel.authenticationState else {
            return XCTFail("Expected reauthentication to succeed")
        }
        XCTAssertEqual(appModel.documentState, .idle)
        XCTAssertNil(appModel.selectedTreeItemID)
    }

    func testReauthenticationPreservesLoadedDirtyDocument() async throws {
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: [file(id: "note", name: "note.md")]),
                TreeResponse(error: .authenticationRequired),
            ],
            controlledDownload: DriveFileDownload(
                item: file(id: "note", name: "note.md"),
                data: Data("saved text".utf8),
                revision: revision()
            )
        )
        let appModel = makeAppModel(driveClient: driveClient)
        await appModel.restoreSession()

        let documentLoad = Task { @MainActor in
            await appModel.selectTreeItem(id: "note")
        }
        await driveClient.waitUntilDownloadStarts()
        await driveClient.completeDownload()
        await documentLoad.value
        appModel.updateDocumentText("unsaved local text")

        await appModel.loadVaultTree()

        XCTAssertEqual(
            appModel.authenticationState,
            .failed(.reauthenticationRequired)
        )
        guard case .loaded(let document) = appModel.documentState else {
            return XCTFail("Expected the dirty document to be retained")
        }
        XCTAssertEqual(document.text, "unsaved local text")
        XCTAssertTrue(document.isDirty)
    }

    private func makeAppModel(
        driveClient: ControlledAppDriveClient,
        vaultStore: any VaultStore = FakeAppVaultStore()
    ) -> AppModel {
        let authenticationController = AuthenticationController(
            service: FakeAppAuthenticationService()
        )
        return AppModel(
            authenticationController: authenticationController,
            driveFolderBrowser: DriveFolderBrowser(driveClient: driveClient),
            vaultTreeLoader: VaultTreeLoader(driveClient: driveClient),
            vaultDocumentLoader: VaultDocumentLoader(driveContentClient: driveClient),
            vaultDocumentSaver: VaultDocumentSaver(driveWriteClient: driveClient),
            vaultStore: vaultStore
        )
    }
}

private struct TreeResponse: Sendable {
    let result: Result<[DriveItem], DriveError>
    let delayNanoseconds: UInt64

    init(items: [DriveItem], delayNanoseconds: UInt64 = 0) {
        result = .success(items)
        self.delayNanoseconds = delayNanoseconds
    }

    init(error: DriveError, delayNanoseconds: UInt64 = 0) {
        result = .failure(error)
        self.delayNanoseconds = delayNanoseconds
    }
}

private actor ControlledAppDriveClient: DriveClient, DriveContentClient, DriveWriteClient {
    private let controlledDownload: DriveFileDownload?
    private var treeResponses: [TreeResponse]
    private var downloadContinuation: CheckedContinuation<DriveFileDownload, Never>?
    private var didStartDownload = false

    init(
        treeResponses: [TreeResponse],
        controlledDownload: DriveFileDownload? = nil
    ) {
        self.treeResponses = treeResponses
        self.controlledDownload = controlledDownload
    }

    func getItem(id: String) async throws -> DriveItem {
        if id == "vault" {
            return folder(id: "vault", name: "Vault")
        }
        return file(id: id, name: "\(id).md")
    }

    func listChildren(of folderID: String) async throws -> [DriveItem] {
        guard folderID == "vault", !treeResponses.isEmpty else {
            return []
        }
        let response = treeResponses.removeFirst()
        if response.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: response.delayNanoseconds)
        }
        return try response.result.get()
    }

    func downloadFile(id: String) async throws -> DriveFileDownload {
        guard controlledDownload != nil else {
            throw DriveError.itemNotFound
        }
        didStartDownload = true
        return await withCheckedContinuation { continuation in
            downloadContinuation = continuation
        }
    }

    func getFileMetadata(id: String) async throws -> DriveFileMetadata {
        throw DriveError.itemNotFound
    }

    func updateFileContent(
        id: String,
        data: Data,
        mimeType: String
    ) async throws -> DriveFileMetadata {
        throw DriveError.itemNotFound
    }

    func createFile(
        name: String,
        parentID: String,
        data: Data,
        mimeType: String
    ) async throws -> DriveFileMetadata {
        throw DriveError.itemNotFound
    }

    func waitUntilDownloadStarts() async {
        while !didStartDownload {
            await Task.yield()
        }
    }

    func completeDownload() {
        guard let controlledDownload else {
            return
        }
        downloadContinuation?.resume(returning: controlledDownload)
        downloadContinuation = nil
    }
}

private actor FakeAppAuthenticationService: AuthenticationService {
    func restoreSession() async throws -> AuthenticatedSession? {
        AuthenticatedSession(accessTokenExpiresAt: .distantFuture)
    }

    func signIn() async throws -> AuthenticatedSession {
        AuthenticatedSession(accessTokenExpiresAt: .distantFuture)
    }

    func signOut() async throws {}

    func validAccessToken() async throws -> AccessToken {
        AccessToken(rawValue: "access-token")
    }

    func refreshAccessToken(afterRejected rejectedToken: AccessToken) async throws -> AccessToken {
        AccessToken(rawValue: "refreshed-access-token")
    }
}

private actor FakeAppVaultStore: VaultStore {
    func loadVault() async throws -> Vault? {
        Vault(rootFolderID: "vault", displayName: "Vault")
    }

    func saveVault(_ vault: Vault) async throws {}

    func clearVault() async throws {}
}

private actor ControlledAppVaultStore: VaultStore {
    private var loadContinuation: CheckedContinuation<Vault?, Never>?
    private var didStartLoad = false

    func loadVault() async throws -> Vault? {
        didStartLoad = true
        return await withCheckedContinuation { continuation in
            loadContinuation = continuation
        }
    }

    func saveVault(_ vault: Vault) async throws {}

    func clearVault() async throws {}

    func waitUntilLoadStarts() async {
        while !didStartLoad {
            await Task.yield()
        }
    }

    func completeLoad(with vault: Vault?) {
        loadContinuation?.resume(returning: vault)
        loadContinuation = nil
    }
}

private func folder(id: String, name: String) -> DriveItem {
    DriveItem(
        id: id,
        name: name,
        kind: .folder,
        mimeType: GoogleDriveAPIClient.folderMimeType
    )
}

private func file(id: String, name: String) -> DriveItem {
    DriveItem(
        id: id,
        name: name,
        kind: .file,
        mimeType: "text/markdown",
        parentIDs: ["vault"]
    )
}

private func revision() -> DriveFileRevision {
    DriveFileRevision(
        version: "1",
        modifiedTime: Date(timeIntervalSince1970: 1_700_000_000)
    )
}
