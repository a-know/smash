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
        appModel.setFolderExpanded(id: "vault", isExpanded: true)

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
        XCTAssertEqual(appModel.expandedFolderIDs, ["vault"])
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

    func testCreatingNewNoteRefreshesTreeAndOpensCreatedFile() async throws {
        let createdFile = file(id: "created", name: "Idea.md")
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: []),
                TreeResponse(items: [createdFile]),
            ],
            controlledDownload: DriveFileDownload(
                item: createdFile,
                data: Data(),
                revision: revision()
            ),
            fileCreationResult: .success(
                DriveFileMetadata(item: createdFile, revision: revision())
            )
        )
        let appModel = makeAppModel(driveClient: driveClient)
        await appModel.restoreSession()
        appModel.presentNewNote()

        let creation = Task { @MainActor in
            await appModel.createNewNote(name: "Idea", parentFolderID: "vault")
        }
        await driveClient.waitUntilDownloadStarts()
        await driveClient.completeDownload()
        await creation.value

        XCTAssertFalse(appModel.isNewNotePresented)
        XCTAssertEqual(appModel.selectedTreeItemID, "created")
        guard case .loaded(let document) = appModel.documentState else {
            return XCTFail("Expected the created note to open")
        }
        XCTAssertEqual(document.name, "Idea.md")
        XCTAssertFalse(document.isDirty)
    }

    func testCreatingFolderWhileEditingPreservesDirtyDocument() async throws {
        let existingFile = file(id: "note", name: "note.md")
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: [existingFile]),
                TreeResponse(items: [
                    existingFile,
                    folder(id: "created-folder", name: "Drafts"),
                ]),
            ],
            controlledDownload: DriveFileDownload(
                item: existingFile,
                data: Data("saved text".utf8),
                revision: revision()
            ),
            folderCreationResult: .success(
                DriveItem(
                    id: "created-folder",
                    name: "Drafts",
                    kind: .folder,
                    mimeType: GoogleDriveAPIClient.folderMimeType,
                    parentIDs: ["vault"]
                )
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

        appModel.presentNewFolder()
        await appModel.createNewFolder(name: "Drafts", parentFolderID: "vault")

        guard case .loaded(let document) = appModel.documentState else {
            return XCTFail("Expected dirty document to remain loaded")
        }
        XCTAssertEqual(document.text, "unsaved local text")
        XCTAssertTrue(document.isDirty)
        guard case .loaded(let tree) = appModel.vaultTreeState else {
            return XCTFail("Expected refreshed Vault tree")
        }
        XCTAssertTrue(tree.containsFolder(id: "created-folder"))
    }

    func testRenamingOpenFilePreservesDirtyTextAndCanSaveWithoutFalseConflict() async throws {
        let existingFile = file(id: "note", name: "note.md")
        let renamedFile = file(id: "note", name: "Renamed.md")
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: [existingFile]),
                TreeResponse(items: [renamedFile]),
            ],
            controlledDownload: DriveFileDownload(
                item: existingFile,
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

        appModel.presentRename(itemID: "note")
        await appModel.renameTarget(to: "Renamed")

        XCTAssertFalse(appModel.isRenamePresented)
        guard case .loaded(let document) = appModel.documentState else {
            return XCTFail("Expected dirty document to remain loaded")
        }
        XCTAssertEqual(document.name, "Renamed.md")
        XCTAssertEqual(document.text, "unsaved local text")
        XCTAssertEqual(document.remoteRevision.version, "2")
        XCTAssertTrue(document.isDirty)
        guard case .loaded(let tree) = appModel.vaultTreeState else {
            return XCTFail("Expected refreshed Vault tree")
        }
        XCTAssertEqual(tree.markdownFile(id: "note")?.name, "Renamed.md")

        await appModel.saveDocument()

        guard case .loaded(let savedDocument) = appModel.documentState else {
            return XCTFail("Expected renamed document to remain loaded after save")
        }
        XCTAssertEqual(savedDocument.name, "Renamed.md")
        XCTAssertEqual(savedDocument.text, "unsaved local text")
        XCTAssertEqual(savedDocument.remoteRevision.version, "3")
        XCTAssertFalse(savedDocument.isDirty)
    }

    func testDuplicateFolderPathsAreDisambiguatedWithDriveIDs() async {
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: [
                    folder(id: "folder-one", name: "Notes"),
                    folder(id: "folder-two", name: "Notes"),
                ])
            ]
        )
        let appModel = makeAppModel(driveClient: driveClient)
        await appModel.restoreSession()

        XCTAssertEqual(
            appModel.availableVaultFolders.map(\.displayPath),
            [
                "Vault",
                "Vault / Notes (folder-one)",
                "Vault / Notes (folder-two)",
            ]
        )
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
            vaultItemCreator: VaultItemCreator(driveClient: driveClient),
            vaultItemRenamer: VaultItemRenamer(driveClient: driveClient),
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

private actor ControlledAppDriveClient: DriveClient, DriveContentClient, DriveWriteClient,
    DriveItemCreationClient, DriveItemMutationClient
{
    private let controlledDownload: DriveFileDownload?
    private let fileCreationResult: Result<DriveFileMetadata, DriveError>
    private let folderCreationResult: Result<DriveItem, DriveError>
    private var renamedItems: [String: DriveItem] = [:]
    private var treeResponses: [TreeResponse]
    private var downloadContinuation: CheckedContinuation<DriveFileDownload, Never>?
    private var didStartDownload = false

    init(
        treeResponses: [TreeResponse],
        controlledDownload: DriveFileDownload? = nil,
        fileCreationResult: Result<DriveFileMetadata, DriveError> = .failure(.itemNotFound),
        folderCreationResult: Result<DriveItem, DriveError> = .failure(.itemNotFound)
    ) {
        self.treeResponses = treeResponses
        self.controlledDownload = controlledDownload
        self.fileCreationResult = fileCreationResult
        self.folderCreationResult = folderCreationResult
    }

    func getItem(id: String) async throws -> DriveItem {
        if id == "vault" {
            return folder(id: "vault", name: "Vault")
        }
        if let renamedItem = renamedItems[id] {
            return renamedItem
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
        guard let item = renamedItems[id] else {
            throw DriveError.itemNotFound
        }
        return DriveFileMetadata(
            item: item,
            revision: DriveFileRevision(
                version: "2",
                modifiedTime: Date(timeIntervalSince1970: 1_700_000_001)
            )
        )
    }

    func updateFileContent(
        id: String,
        data: Data,
        mimeType: String
    ) async throws -> DriveFileMetadata {
        guard let item = renamedItems[id] else {
            throw DriveError.itemNotFound
        }
        return DriveFileMetadata(
            item: item,
            revision: DriveFileRevision(
                version: "3",
                modifiedTime: Date(timeIntervalSince1970: 1_700_000_002)
            )
        )
    }

    func createFile(
        name: String,
        parentID: String,
        data: Data,
        mimeType: String
    ) async throws -> DriveFileMetadata {
        try fileCreationResult.get()
    }

    func createFolder(name: String, parentID: String) async throws -> DriveItem {
        try folderCreationResult.get()
    }

    func trashItem(id: String) async throws -> DriveItem {
        throw DriveError.itemNotFound
    }

    func renameItem(id: String, name: String) async throws -> DriveItemRenameResult {
        let item = file(id: id, name: name)
        renamedItems[id] = item
        return DriveItemRenameResult(
            item: item,
            revision: DriveFileRevision(
                version: "2",
                modifiedTime: Date(timeIntervalSince1970: 1_700_000_001)
            )
        )
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
