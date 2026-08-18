import Foundation
import MarkdownDriveCore
import XCTest

@testable import MarkdownDriveMac

@MainActor
final class AppModelConcurrencyTests: XCTestCase {
    func testVaultCannotChangeWhileSignedOut() async {
        let driveClient = ControlledAppDriveClient(treeResponses: [])
        let appModel = makeAppModel(driveClient: driveClient)

        XCTAssertEqual(appModel.authenticationState, .signedOut)
        XCTAssertFalse(appModel.canChangeVault)

        await appModel.presentVaultBrowser()

        XCTAssertFalse(appModel.isVaultBrowserPresented)
        let listChildrenRequestCount = await driveClient.listChildrenRequestCount
        XCTAssertEqual(listChildrenRequestCount, 0)
    }

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

    func testRefreshAvailabilityTracksVaultTreeLoading() async throws {
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: [file(id: "initial", name: "initial.md")]),
                TreeResponse(items: [file(id: "refreshed", name: "refreshed.md")]),
            ],
            waitsForSecondListChildrenCompletion: true
        )
        let appModel = makeAppModel(driveClient: driveClient)
        await appModel.restoreSession()
        XCTAssertTrue(appModel.canRefreshVault)

        let refresh = Task { @MainActor in
            await appModel.refreshVault()
        }
        try await driveClient.waitUntilSecondListChildrenStarts()

        XCTAssertFalse(appModel.canRefreshVault)
        await appModel.refreshVault()
        await driveClient.completeSecondListChildren()

        await refresh.value
        XCTAssertTrue(appModel.canRefreshVault)
        let listChildrenRequestCount = await driveClient.listChildrenRequestCount
        XCTAssertEqual(listChildrenRequestCount, 2)
    }

    func testRefreshIsUnavailableAfterAuthenticationFailure() async {
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: [file(id: "initial", name: "initial.md")]),
                TreeResponse(error: .authenticationRequired),
            ]
        )
        let appModel = makeAppModel(driveClient: driveClient)
        await appModel.restoreSession()

        await appModel.refreshVault()

        XCTAssertNotNil(appModel.selectedVault)
        XCTAssertFalse(appModel.canRefreshVault)
        XCTAssertFalse(appModel.canChangeVault)
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

    func testSavingOpenFilePreventsOverlappingRename() async throws {
        let existingFile = file(id: "note", name: "note.md")
        let driveClient = ControlledAppDriveClient(
            treeResponses: [TreeResponse(items: [existingFile])],
            controlledDownload: DriveFileDownload(
                item: existingFile,
                data: Data("saved text".utf8),
                revision: revision()
            ),
            waitsForUpdateCompletion: true
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

        let save = Task { @MainActor in
            await appModel.saveDocument()
        }
        await driveClient.waitUntilUpdateStarts()

        XCTAssertFalse(appModel.canRenameItem(id: "note"))
        appModel.presentRename(itemID: "note")
        XCTAssertFalse(appModel.isRenamePresented)
        let renameRequestCount = await driveClient.renameRequestCount
        XCTAssertEqual(renameRequestCount, 0)

        await driveClient.completeUpdate()
        await save.value
    }

    func testCreatingVaultItemPreventsOverlappingRename() async throws {
        let existingFile = file(id: "note", name: "note.md")
        let createdFolder = folder(id: "created-folder", name: "Drafts")
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: [existingFile]),
                TreeResponse(items: [existingFile, createdFolder]),
            ],
            folderCreationResult: .success(createdFolder),
            waitsForCreationCompletion: true
        )
        let appModel = makeAppModel(driveClient: driveClient)
        await appModel.restoreSession()
        appModel.presentNewFolder()

        let creation = Task { @MainActor in
            await appModel.createNewFolder(name: "Drafts", parentFolderID: "vault")
        }
        try await driveClient.waitUntilCreationStarts()

        XCTAssertFalse(appModel.canRenameItem(id: "note"))
        appModel.presentRename(itemID: "note")
        XCTAssertFalse(appModel.isRenamePresented)
        XCTAssertTrue(appModel.isNewFolderPresented)
        let renameRequestCount = await driveClient.renameRequestCount
        XCTAssertEqual(renameRequestCount, 0)

        await driveClient.completeCreation()
        await creation.value
    }

    func testRenamingOpenFilePreventsOverlappingSave() async throws {
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
            ),
            waitsForRenameCompletion: true
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

        let rename = Task { @MainActor in
            await appModel.renameTarget(to: "Renamed")
        }
        await driveClient.waitUntilRenameStarts()

        XCTAssertFalse(appModel.canSaveDocument)
        XCTAssertFalse(appModel.canCreateVaultItems)
        appModel.presentNewNote()
        appModel.presentNewFolder()
        XCTAssertFalse(appModel.isNewNotePresented)
        XCTAssertFalse(appModel.isNewFolderPresented)
        XCTAssertTrue(appModel.isRenamePresented)
        XCTAssertEqual(appModel.vaultItemRenameState, .renaming)
        await appModel.saveDocument()
        let updateRequestCount = await driveClient.updateRequestCount
        XCTAssertEqual(updateRequestCount, 0)

        await driveClient.completeRename()
        await rename.value
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

    func testTrashItemRefreshesTreeAfterConfirmedGoogleDriveTrash() async {
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: [file(id: "note", name: "note.md")]),
                TreeResponse(items: []),
            ]
        )
        let appModel = makeAppModel(driveClient: driveClient)
        await appModel.restoreSession()

        appModel.presentTrash(itemID: "note")
        XCTAssertTrue(appModel.isTrashConfirmationPresented)
        XCTAssertEqual(appModel.trashTargetItem?.id, "note")

        await appModel.confirmTrash(itemID: "note")

        let trashRequestCount = await driveClient.trashRequestCount
        XCTAssertEqual(trashRequestCount, 1)
        XCTAssertEqual(appModel.vaultItemTrashState, .idle)
        XCTAssertFalse(appModel.isTrashConfirmationPresented)
        guard case .loaded(let tree) = appModel.vaultTreeState else {
            return XCTFail("Expected the Vault tree to refresh")
        }
        XCTAssertNil(tree.item(id: "note"))
    }

    func testDirtyOpenDocumentCannotBeMovedToTrash() async {
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
        await driveClient.completeDownload()
        await documentLoad.value
        appModel.updateDocumentText("unsaved local text")

        XCTAssertFalse(appModel.canTrashItem(id: "note"))
        appModel.presentTrash(itemID: "note")
        XCTAssertFalse(appModel.isTrashConfirmationPresented)
        let trashRequestCount = await driveClient.trashRequestCount
        XCTAssertEqual(trashRequestCount, 0)
    }

    func testAffectedDocumentCannotBecomeDirtyWhileTrashIsInFlight() async throws {
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: [file(id: "note", name: "note.md")]),
                TreeResponse(items: []),
            ],
            controlledDownload: DriveFileDownload(
                item: file(id: "note", name: "note.md"),
                data: Data("remote text".utf8),
                revision: revision()
            ),
            waitsForTrashCompletion: true
        )
        let appModel = makeAppModel(driveClient: driveClient)
        await appModel.restoreSession()

        let documentLoad = Task { @MainActor in
            await appModel.selectTreeItem(id: "note")
        }
        await driveClient.waitUntilDownloadStarts()
        await driveClient.completeDownload()
        await documentLoad.value
        appModel.presentTrash(itemID: "note")

        let trash = Task { @MainActor in
            await appModel.confirmTrash(itemID: "note")
        }
        try await driveClient.waitUntilTrashStarts()

        XCTAssertFalse(appModel.isDocumentEditingEnabled)
        appModel.updateDocumentText("late unsaved text")
        guard case .loaded(let document) = appModel.documentState else {
            return XCTFail("Expected the clean document to remain open while Trash is pending")
        }
        XCTAssertEqual(document.text, "remote text")
        XCTAssertFalse(document.isDirty)

        await driveClient.completeTrash()
        await trash.value
        XCTAssertEqual(appModel.documentState, .idle)
    }

    func testVaultCannotChangeWhileTrashIsInFlight() async throws {
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: [file(id: "note", name: "note.md")]),
                TreeResponse(items: []),
            ],
            waitsForTrashCompletion: true
        )
        let appModel = makeAppModel(driveClient: driveClient)
        await appModel.restoreSession()
        appModel.presentTrash(itemID: "note")

        let trash = Task { @MainActor in
            await appModel.confirmTrash(itemID: "note")
        }
        try await driveClient.waitUntilTrashStarts()

        XCTAssertFalse(appModel.canChangeVault)
        await appModel.presentVaultBrowser()
        XCTAssertFalse(appModel.isVaultBrowserPresented)

        await driveClient.completeTrash()
        await trash.value
    }

    func testAffectedDocumentLoadCannotCompleteAfterTrashSucceeds() async throws {
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: [file(id: "note", name: "note.md")]),
                TreeResponse(items: []),
            ],
            controlledDownload: DriveFileDownload(
                item: file(id: "note", name: "note.md"),
                data: Data("stale text".utf8),
                revision: revision()
            ),
            waitsForTrashCompletion: true
        )
        let appModel = makeAppModel(driveClient: driveClient)
        await appModel.restoreSession()
        appModel.presentTrash(itemID: "note")

        let trash = Task { @MainActor in
            await appModel.confirmTrash(itemID: "note")
        }
        try await driveClient.waitUntilTrashStarts()
        let documentLoad = Task { @MainActor in
            await appModel.selectTreeItem(id: "note")
        }
        await driveClient.waitUntilDownloadStarts()

        await driveClient.completeTrash()
        await trash.value
        await driveClient.completeDownload()
        await documentLoad.value

        XCTAssertEqual(appModel.documentState, .idle)
        XCTAssertNil(appModel.selectedTreeItemID)
    }

    func testUnknownTrashStatusRemainsLockedUntilReconciliation() async {
        let note = file(id: "note", name: "note.md")
        let driveClient = ControlledAppDriveClient(
            treeResponses: [
                TreeResponse(items: [note]),
                TreeResponse(items: []),
            ],
            trashError: .writeStatusUnknown,
            trashReconciliationItem: trashed(note),
            waitsForTrashReconciliationCompletion: true
        )
        let appModel = makeAppModel(driveClient: driveClient)
        await appModel.restoreSession()
        appModel.presentTrash(itemID: "note")

        await appModel.confirmTrash(itemID: "note")

        guard case .statusUnknown = appModel.vaultItemTrashState else {
            return XCTFail("Expected unknown Trash status")
        }
        XCTAssertFalse(appModel.canCreateVaultItems)
        XCTAssertFalse(appModel.canTrashItem(id: "note"))

        let reconciliation = Task { @MainActor in
            await appModel.dismissTrashErrorAlert()
        }
        await driveClient.waitUntilTrashReconciliationStarts()
        XCTAssertEqual(appModel.vaultItemTrashState, .reconciling)
        XCTAssertFalse(appModel.canCreateVaultItems)
        XCTAssertFalse(appModel.canTrashItem(id: "note"))

        await driveClient.completeTrashReconciliation()
        await reconciliation.value

        XCTAssertEqual(appModel.vaultItemTrashState, .idle)
        guard case .loaded(let tree) = appModel.vaultTreeState else {
            return XCTFail("Expected reconciliation to refresh the Vault tree")
        }
        XCTAssertNil(tree.item(id: "note"))
    }

    func testUnknownTrashStatusPreventsChangingVault() async {
        let note = file(id: "note", name: "note.md")
        let driveClient = ControlledAppDriveClient(
            treeResponses: [TreeResponse(items: [note])],
            trashError: .writeStatusUnknown
        )
        let appModel = makeAppModel(driveClient: driveClient)
        await appModel.restoreSession()
        appModel.presentTrash(itemID: "note")

        await appModel.confirmTrash(itemID: "note")

        XCTAssertFalse(appModel.canChangeVault)
        await appModel.presentVaultBrowser()
        XCTAssertFalse(appModel.isVaultBrowserPresented)
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
            vaultItemTrasher: VaultItemTrasher(driveClient: driveClient),
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
    private let waitsForUpdateCompletion: Bool
    private let waitsForRenameCompletion: Bool
    private let waitsForCreationCompletion: Bool
    private let waitsForTrashCompletion: Bool
    private let trashError: DriveError?
    private let trashReconciliationItem: DriveItem?
    private let waitsForTrashReconciliationCompletion: Bool
    private let waitsForSecondListChildrenCompletion: Bool
    private var renamedItems: [String: DriveItem] = [:]
    private var treeResponses: [TreeResponse]
    private var downloadContinuation: CheckedContinuation<DriveFileDownload, Never>?
    private var updateContinuation: CheckedContinuation<Void, Never>?
    private var renameContinuation: CheckedContinuation<Void, Never>?
    private var creationContinuation: CheckedContinuation<Void, Never>?
    private var trashContinuation: CheckedContinuation<Void, Never>?
    private var trashReconciliationContinuation: CheckedContinuation<Void, Never>?
    private var secondListChildrenContinuation: CheckedContinuation<Void, Never>?
    private var didStartDownload = false
    private var didStartUpdate = false
    private var didStartRename = false
    private var didStartCreation = false
    private var didStartTrash = false
    private var didReturnUnknownTrashStatus = false
    private var didStartTrashReconciliation = false
    private var didStartSecondListChildren = false
    private(set) var updateRequestCount = 0
    private(set) var renameRequestCount = 0
    private(set) var trashRequestCount = 0
    private(set) var listChildrenRequestCount = 0

    init(
        treeResponses: [TreeResponse],
        controlledDownload: DriveFileDownload? = nil,
        fileCreationResult: Result<DriveFileMetadata, DriveError> = .failure(.itemNotFound),
        folderCreationResult: Result<DriveItem, DriveError> = .failure(.itemNotFound),
        waitsForUpdateCompletion: Bool = false,
        waitsForRenameCompletion: Bool = false,
        waitsForCreationCompletion: Bool = false,
        waitsForTrashCompletion: Bool = false,
        trashError: DriveError? = nil,
        trashReconciliationItem: DriveItem? = nil,
        waitsForTrashReconciliationCompletion: Bool = false,
        waitsForSecondListChildrenCompletion: Bool = false
    ) {
        self.treeResponses = treeResponses
        self.controlledDownload = controlledDownload
        self.fileCreationResult = fileCreationResult
        self.folderCreationResult = folderCreationResult
        self.waitsForUpdateCompletion = waitsForUpdateCompletion
        self.waitsForRenameCompletion = waitsForRenameCompletion
        self.waitsForCreationCompletion = waitsForCreationCompletion
        self.waitsForTrashCompletion = waitsForTrashCompletion
        self.trashError = trashError
        self.trashReconciliationItem = trashReconciliationItem
        self.waitsForTrashReconciliationCompletion = waitsForTrashReconciliationCompletion
        self.waitsForSecondListChildrenCompletion = waitsForSecondListChildrenCompletion
    }

    func getItem(id: String) async throws -> DriveItem {
        if id == "vault" {
            return folder(id: "vault", name: "Vault")
        }
        if let renamedItem = renamedItems[id] {
            return renamedItem
        }
        if didReturnUnknownTrashStatus, let trashReconciliationItem {
            didStartTrashReconciliation = true
            if waitsForTrashReconciliationCompletion {
                await withCheckedContinuation { continuation in
                    trashReconciliationContinuation = continuation
                }
            }
            return trashReconciliationItem
        }
        return file(id: id, name: "\(id).md")
    }

    func listChildren(of folderID: String) async throws -> [DriveItem] {
        listChildrenRequestCount += 1
        if waitsForSecondListChildrenCompletion,
            listChildrenRequestCount == 2
        {
            didStartSecondListChildren = true
            await withCheckedContinuation { continuation in
                secondListChildrenContinuation = continuation
            }
        }
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
        guard let item = renamedItems[id] ?? controlledDownload?.item else {
            throw DriveError.itemNotFound
        }
        if renamedItems[id] == nil, let controlledDownload {
            return DriveFileMetadata(
                item: item,
                revision: controlledDownload.revision
            )
        }
        return DriveFileMetadata(
            item: item,
            revision: DriveFileRevision(
                version: "2",
                modifiedTime: Date(timeIntervalSince1970: 1_700_000_001),
                contentChecksum: "content-a"
            )
        )
    }

    func getFileRevision(id: String) async throws -> DriveFileMetadata {
        try await getFileMetadata(id: id)
    }

    func updateFileContent(
        id: String,
        data: Data,
        mimeType: String
    ) async throws -> DriveFileMetadata {
        updateRequestCount += 1
        didStartUpdate = true
        if waitsForUpdateCompletion {
            await withCheckedContinuation { continuation in
                updateContinuation = continuation
            }
        }
        guard let item = renamedItems[id] ?? controlledDownload?.item else {
            throw DriveError.itemNotFound
        }
        let version = renamedItems[id] == nil ? "2" : "3"
        return DriveFileMetadata(
            item: item,
            revision: DriveFileRevision(
                version: version,
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
        didStartCreation = true
        if waitsForCreationCompletion {
            await withCheckedContinuation { continuation in
                creationContinuation = continuation
            }
        }
        return try fileCreationResult.get()
    }

    func createFolder(name: String, parentID: String) async throws -> DriveItem {
        didStartCreation = true
        if waitsForCreationCompletion {
            await withCheckedContinuation { continuation in
                creationContinuation = continuation
            }
        }
        return try folderCreationResult.get()
    }

    func trashItem(id: String) async throws -> DriveItem {
        trashRequestCount += 1
        didStartTrash = true
        if waitsForTrashCompletion {
            await withCheckedContinuation { continuation in
                trashContinuation = continuation
            }
        }
        if let trashError {
            didReturnUnknownTrashStatus = true
            throw trashError
        }
        let currentItem = try await getItem(id: id)
        return DriveItem(
            id: currentItem.id,
            name: currentItem.name,
            kind: currentItem.kind,
            mimeType: currentItem.mimeType,
            parentIDs: currentItem.parentIDs,
            isTrashed: true,
            capabilities: currentItem.capabilities
        )
    }

    func renameItem(id: String, name: String) async throws -> DriveItemRenameResult {
        renameRequestCount += 1
        didStartRename = true
        if waitsForRenameCompletion {
            await withCheckedContinuation { continuation in
                renameContinuation = continuation
            }
        }
        let item = file(id: id, name: name)
        renamedItems[id] = item
        return DriveItemRenameResult(
            item: item,
            revision: DriveFileRevision(
                version: "2",
                modifiedTime: Date(timeIntervalSince1970: 1_700_000_001),
                contentChecksum: "content-a"
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

    func waitUntilUpdateStarts() async {
        while !didStartUpdate {
            await Task.yield()
        }
    }

    func completeUpdate() {
        updateContinuation?.resume()
        updateContinuation = nil
    }

    func waitUntilRenameStarts() async {
        while !didStartRename {
            await Task.yield()
        }
    }

    func completeRename() {
        renameContinuation?.resume()
        renameContinuation = nil
    }

    func waitUntilCreationStarts() async throws {
        for _ in 0..<500 {
            if didStartCreation {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AppModelTestSynchronizationError.timedOut
    }

    func completeCreation() {
        creationContinuation?.resume()
        creationContinuation = nil
    }

    func waitUntilTrashStarts() async throws {
        for _ in 0..<500 {
            if didStartTrash {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AppModelTestSynchronizationError.timedOut
    }

    func completeTrash() {
        trashContinuation?.resume()
        trashContinuation = nil
    }

    func waitUntilTrashReconciliationStarts() async {
        while !didStartTrashReconciliation {
            await Task.yield()
        }
    }

    func completeTrashReconciliation() {
        trashReconciliationContinuation?.resume()
        trashReconciliationContinuation = nil
    }

    func waitUntilSecondListChildrenStarts() async throws {
        for _ in 0..<500 {
            if didStartSecondListChildren {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AppModelTestSynchronizationError.timedOut
    }

    func completeSecondListChildren() {
        secondListChildrenContinuation?.resume()
        secondListChildrenContinuation = nil
    }
}

private enum AppModelTestSynchronizationError: Error {
    case timedOut
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
        mimeType: GoogleDriveAPIClient.folderMimeType,
        capabilities: DriveItemCapabilities(canRename: true, canTrash: true)
    )
}

private func file(id: String, name: String) -> DriveItem {
    DriveItem(
        id: id,
        name: name,
        kind: .file,
        mimeType: "text/markdown",
        parentIDs: ["vault"],
        capabilities: DriveItemCapabilities(canRename: true, canTrash: true)
    )
}

private func revision() -> DriveFileRevision {
    DriveFileRevision(
        version: "1",
        modifiedTime: Date(timeIntervalSince1970: 1_700_000_000),
        contentChecksum: "content-a"
    )
}

private func trashed(_ item: DriveItem) -> DriveItem {
    DriveItem(
        id: item.id,
        name: item.name,
        kind: item.kind,
        mimeType: item.mimeType,
        parentIDs: item.parentIDs,
        isTrashed: true,
        capabilities: item.capabilities
    )
}
