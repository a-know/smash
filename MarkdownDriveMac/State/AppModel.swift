import Combine
import Foundation
import MarkdownDriveCore

enum VaultBrowserState: Equatable {
    case idle
    case loading
    case loaded(DriveFolderBrowserSnapshot)
    case failed(String)
}

enum VaultTreeState: Equatable {
    case idle
    case loading
    case loaded(VaultTree)
    case failed(String)
}

enum DocumentState: Equatable {
    case idle
    case loading(fileID: String)
    case loaded(MarkdownDocument)
    case failed(fileID: String, message: String)
}

enum DocumentSaveState: Equatable {
    case idle
    case saving
    case saved
    case failed(String)
    case conflict
    case reloadFailed(String)
    case statusUnknown(String)
}

enum VaultItemCreationState: Equatable {
    case idle
    case creating
    case failed(String)
    case statusUnknown(String)
}

enum VaultItemRenameState: Equatable {
    case idle
    case renaming
    case failed(String)
    case statusUnknown(String)
}

enum VaultItemTrashState: Equatable {
    case idle
    case trashing
    case reconciling
    case failed(String)
    case statusUnknown(String)
}

struct VaultFolderDestination: Equatable, Identifiable {
    let id: String
    let displayPath: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var authenticationState: AuthenticationState
    @Published private(set) var selectedVault: Vault?
    @Published private(set) var vaultPersistenceError: String?
    @Published private(set) var vaultBrowserState: VaultBrowserState = .idle
    @Published private(set) var vaultTreeState: VaultTreeState = .idle
    @Published private(set) var documentState: DocumentState = .idle
    @Published private(set) var documentSaveState: DocumentSaveState = .idle
    @Published private(set) var selectedTreeItemID: String?
    @Published private(set) var expandedFolderIDs: Set<String> = []
    @Published private(set) var pendingDocumentFileID: String?
    @Published private(set) var isDiscardConfirmationPresented = false
    @Published private(set) var isConflictAlertPresented = false
    @Published private(set) var isSaveErrorAlertPresented = false
    @Published private(set) var isVaultBrowserPresented = false
    @Published private(set) var isNewNotePresented = false
    @Published private(set) var isNewFolderPresented = false
    @Published private(set) var vaultItemCreationState: VaultItemCreationState = .idle
    @Published private(set) var isRenamePresented = false
    @Published private(set) var vaultItemRenameState: VaultItemRenameState = .idle
    @Published private(set) var isTrashConfirmationPresented = false
    @Published private(set) var isTrashErrorAlertPresented = false
    @Published private(set) var vaultItemTrashState: VaultItemTrashState = .idle

    private let authenticationController: AuthenticationController
    private let driveFolderBrowser: DriveFolderBrowser
    private let vaultTreeLoader: VaultTreeLoader
    private let vaultDocumentLoader: VaultDocumentLoader
    private let vaultDocumentSaver: VaultDocumentSaver
    private let vaultItemCreator: VaultItemCreator
    private let vaultItemRenamer: VaultItemRenamer
    private let vaultItemTrasher: VaultItemTrasher
    private let vaultStore: any VaultStore
    private var didAttemptRestore = false
    private var authenticationGeneration: UInt64 = 0
    private var vaultRestoreID: UUID?
    private var vaultBrowserLoadID: UUID?
    private var vaultTreeLoadID: UUID?
    private var documentLoadID: UUID?
    private var vaultItemCreationID: UUID?
    private var vaultItemRenameID: UUID?
    private var renameTargetItemID: String?
    private var vaultItemTrashID: UUID?
    private var trashTargetItemID: String?
    private var trashAffectedItemIDs: Set<String> = []
    private var trashVaultTree: VaultTree?

    init(
        authenticationController: AuthenticationController,
        driveFolderBrowser: DriveFolderBrowser,
        vaultTreeLoader: VaultTreeLoader,
        vaultDocumentLoader: VaultDocumentLoader,
        vaultDocumentSaver: VaultDocumentSaver,
        vaultItemCreator: VaultItemCreator,
        vaultItemRenamer: VaultItemRenamer,
        vaultItemTrasher: VaultItemTrasher,
        vaultStore: any VaultStore,
        initialAuthenticationState: AuthenticationState = .signedOut
    ) {
        self.authenticationController = authenticationController
        self.driveFolderBrowser = driveFolderBrowser
        self.vaultTreeLoader = vaultTreeLoader
        self.vaultDocumentLoader = vaultDocumentLoader
        self.vaultDocumentSaver = vaultDocumentSaver
        self.vaultItemCreator = vaultItemCreator
        self.vaultItemRenamer = vaultItemRenamer
        self.vaultItemTrasher = vaultItemTrasher
        self.vaultStore = vaultStore
        authenticationState = initialAuthenticationState
    }

    func restoreSession() async {
        guard !didAttemptRestore else {
            return
        }
        didAttemptRestore = true
        let generation = beginAuthenticationTransition()
        authenticationState = .restoring
        let restoredState = await authenticationController.restoreSession()
        guard authenticationGeneration == generation else {
            return
        }
        authenticationState = restoredState
        await restoreVaultIfAuthenticated()
    }

    func signIn() async {
        let generation = beginAuthenticationTransition()
        authenticationState = .signingIn
        let signedInState = await authenticationController.signIn()
        guard authenticationGeneration == generation else {
            return
        }
        authenticationState = signedInState
        await restoreVaultIfAuthenticated()
    }

    func signOut() async {
        guard !hasDirtyDocument else {
            return
        }
        let generation = beginAuthenticationTransition()
        let signedOutState = await authenticationController.signOut()
        guard authenticationGeneration == generation else {
            return
        }
        authenticationState = signedOutState
        if authenticationState == .signedOut {
            selectedVault = nil
            vaultTreeState = .idle
            clearDocument()
            dismissVaultBrowser()
        }
    }

    func presentVaultBrowser() async {
        guard canChangeVault else {
            return
        }
        isVaultBrowserPresented = true
        await loadMyDrive()
    }

    func dismissVaultBrowser() {
        vaultBrowserLoadID = nil
        isVaultBrowserPresented = false
        vaultBrowserState = .idle
    }

    func loadMyDrive() async {
        await updateBrowserState {
            try await driveFolderBrowser.loadMyDrive()
        }
    }

    func openFolder(id: String) async {
        await updateBrowserState {
            try await driveFolderBrowser.openFolder(id: id)
        }
    }

    func navigateBack() async {
        await updateBrowserState {
            try await driveFolderBrowser.navigateBack()
        }
    }

    func selectCurrentFolderAsVault() async {
        guard canChangeVault else {
            return
        }
        let generation = authenticationGeneration
        vaultRestoreID = nil
        do {
            let vault = try await driveFolderBrowser.makeVault()
            guard authenticationGeneration == generation else {
                return
            }
            try await vaultStore.saveVault(vault)
            guard authenticationGeneration == generation else {
                return
            }
            selectedVault = vault
            clearDocument()
            vaultPersistenceError = nil
            dismissVaultBrowser()
            await loadVaultTree()
        } catch {
            guard authenticationGeneration == generation else {
                return
            }
            vaultBrowserState = .failed(error.localizedDescription)
            transitionToReauthenticationIfNeeded(error)
        }
    }

    private func updateBrowserState(
        operation: () async throws -> DriveFolderBrowserSnapshot
    ) async {
        let loadID = UUID()
        let generation = authenticationGeneration
        vaultBrowserLoadID = loadID
        vaultBrowserState = .loading
        do {
            let snapshot = try await operation()
            guard vaultBrowserLoadID == loadID,
                authenticationGeneration == generation,
                isVaultBrowserPresented
            else {
                return
            }
            vaultBrowserState = .loaded(snapshot)
        } catch {
            guard vaultBrowserLoadID == loadID,
                authenticationGeneration == generation,
                isVaultBrowserPresented
            else {
                return
            }
            vaultBrowserState = .failed(error.localizedDescription)
            transitionToReauthenticationIfNeeded(error)
        }
    }

    private func restoreVaultIfAuthenticated() async {
        guard case .signedIn = authenticationState else {
            return
        }
        let restoreID = UUID()
        let generation = authenticationGeneration
        vaultRestoreID = restoreID
        do {
            let restoredVault = try await vaultStore.loadVault()
            guard vaultRestoreID == restoreID,
                authenticationGeneration == generation,
                case .signedIn = authenticationState
            else {
                return
            }
            vaultTreeLoadID = nil
            selectedVault = restoredVault
            vaultPersistenceError = nil
            await loadVaultTree()
        } catch {
            guard vaultRestoreID == restoreID,
                authenticationGeneration == generation,
                case .signedIn = authenticationState
            else {
                return
            }
            selectedVault = nil
            vaultPersistenceError = "The saved Vault selection could not be restored."
        }
    }

    func loadVaultTree() async {
        guard let selectedVault else {
            vaultTreeLoadID = nil
            vaultTreeState = .idle
            return
        }
        let loadID = UUID()
        let generation = authenticationGeneration
        let vaultRootFolderID = selectedVault.rootFolderID
        vaultTreeLoadID = loadID
        vaultTreeState = .loading
        do {
            let tree = try await vaultTreeLoader.load(vault: selectedVault)
            guard vaultTreeLoadID == loadID,
                authenticationGeneration == generation,
                self.selectedVault?.rootFolderID == vaultRootFolderID
            else {
                return
            }
            vaultTreeState = .loaded(tree)
        } catch {
            guard vaultTreeLoadID == loadID,
                authenticationGeneration == generation,
                self.selectedVault?.rootFolderID == vaultRootFolderID
            else {
                return
            }
            vaultTreeState = .failed(error.localizedDescription)
            transitionToReauthenticationIfNeeded(error)
        }
    }

    var canRefreshVault: Bool {
        guard selectedVault != nil else {
            return false
        }
        if case .loading = vaultTreeState {
            return false
        }
        return true
    }

    func refreshVault() async {
        guard canRefreshVault else {
            return
        }
        await loadVaultTree()
    }

    var canCreateVaultItems: Bool {
        guard case .signedIn = authenticationState,
            case .loaded = vaultTreeState,
            vaultItemCreationState != .creating,
            vaultItemRenameState != .renaming,
            vaultItemTrashState != .trashing,
            trashTargetItemID == nil
        else {
            return false
        }
        return true
    }

    var canChangeVault: Bool {
        !hasDirtyDocument && !isTrashStatusLocked
    }

    var availableVaultFolders: [VaultFolderDestination] {
        guard case .loaded(let tree) = vaultTreeState else {
            return []
        }
        let destinations = Self.folderDestinations(in: tree.root, parentPath: nil)
        let pathCounts = Dictionary(grouping: destinations, by: \.displayPath)
            .mapValues(\.count)
        return destinations.map { destination in
            guard pathCounts[destination.displayPath, default: 0] > 1 else {
                return destination
            }
            return VaultFolderDestination(
                id: destination.id,
                displayPath: "\(destination.displayPath) (\(destination.id))"
            )
        }
    }

    var defaultCreationFolderID: String? {
        guard case .loaded(let tree) = vaultTreeState else {
            return nil
        }
        if let selectedTreeItemID,
            let selectedFolder = tree.folder(id: selectedTreeItemID)
        {
            return selectedFolder.id
        }
        if let selectedTreeItemID,
            let selectedFile = tree.markdownFile(id: selectedTreeItemID),
            let parentID = selectedFile.parentIDs.first(where: tree.containsFolder)
        {
            return parentID
        }
        return tree.root.item.id
    }

    var renameTargetItem: DriveItem? {
        guard case .loaded(let tree) = vaultTreeState,
            let renameTargetItemID,
            renameTargetItemID != tree.root.item.id
        else {
            return nil
        }
        return tree.item(id: renameTargetItemID)
    }

    var canRenameSelectedItem: Bool {
        guard let selectedTreeItemID else {
            return false
        }
        return canRenameItem(id: selectedTreeItemID)
    }

    func canRenameItem(id: String) -> Bool {
        guard case .signedIn = authenticationState,
            case .loaded(let tree) = vaultTreeState,
            id != tree.root.item.id,
            let item = tree.item(id: id),
            item.capabilities?.canRename != false,
            vaultItemCreationState != .creating,
            vaultItemRenameState != .renaming,
            vaultItemTrashState != .trashing,
            trashTargetItemID == nil
        else {
            return false
        }
        if documentSaveState == .saving,
            case .loaded(let document) = documentState,
            document.fileID == id
        {
            return false
        }
        return true
    }

    func presentRenameSelectedItem() {
        guard let selectedTreeItemID else {
            return
        }
        presentRename(itemID: selectedTreeItemID)
    }

    func presentRename(itemID: String) {
        guard canRenameItem(id: itemID) else {
            return
        }
        vaultItemCreationID = nil
        isNewNotePresented = false
        isNewFolderPresented = false
        vaultItemCreationState = .idle
        renameTargetItemID = itemID
        vaultItemRenameState = .idle
        isRenamePresented = true
    }

    func dismissRename() {
        guard vaultItemRenameState != .renaming else {
            return
        }
        resetRenameState()
    }

    func renameTarget(to name: String) async {
        guard let renameTargetItemID,
            canRenameItem(id: renameTargetItemID),
            case .loaded(let tree) = vaultTreeState
        else {
            return
        }
        let expectedRevision: DriveFileRevision?
        if case .loaded(let document) = documentState,
            document.fileID == renameTargetItemID
        {
            expectedRevision = document.remoteRevision
        } else {
            expectedRevision = nil
        }
        let renameID = UUID()
        let generation = authenticationGeneration
        vaultItemRenameID = renameID
        vaultItemRenameState = .renaming

        do {
            let result = try await vaultItemRenamer.rename(
                itemID: renameTargetItemID,
                to: name,
                in: tree,
                expectedRevision: expectedRevision
            )
            guard vaultItemRenameID == renameID,
                authenticationGeneration == generation
            else {
                return
            }
            if case .loaded(var document) = documentState,
                document.fileID == result.item.id,
                let revision = result.revision
            {
                document.recordRename(name: result.item.name, revision: revision)
                documentState = .loaded(document)
            }
            resetRenameState()
            await loadVaultTree()
        } catch {
            guard vaultItemRenameID == renameID,
                authenticationGeneration == generation
            else {
                return
            }
            if let driveError = error as? DriveError,
                driveError == .writeStatusUnknown
            {
                vaultItemRenameState = .statusUnknown(driveError.localizedDescription)
            } else {
                vaultItemRenameState = .failed(error.localizedDescription)
            }
            transitionToReauthenticationIfNeeded(error)
        }
    }

    var trashTargetItem: DriveItem? {
        guard case .loaded(let tree) = vaultTreeState,
            let trashTargetItemID,
            trashTargetItemID != tree.root.item.id
        else {
            return nil
        }
        return tree.item(id: trashTargetItemID)
    }

    var canTrashSelectedItem: Bool {
        guard let selectedTreeItemID else {
            return false
        }
        return canTrashItem(id: selectedTreeItemID)
    }

    func canTrashItem(id: String) -> Bool {
        guard case .signedIn = authenticationState,
            case .loaded(let tree) = vaultTreeState,
            id != tree.root.item.id,
            let item = tree.item(id: id),
            item.capabilities?.canTrash == true
                || item.capabilities?.canMoveItemWithinDrive == true,
            vaultItemCreationState != .creating,
            vaultItemRenameState != .renaming,
            vaultItemTrashState == .idle,
            trashTargetItemID == nil || trashTargetItemID == id,
            !isVaultBrowserPresented,
            documentSaveState != .saving
        else {
            return false
        }
        let affectedIDs = Self.itemIDs(in: tree.root, rootedAt: id)
        if case .loaded(let document) = documentState,
            document.isDirty,
            affectedIDs.contains(document.fileID)
        {
            return false
        }
        if case .loading(let fileID) = documentState,
            affectedIDs.contains(fileID)
        {
            return false
        }
        return true
    }

    func presentTrashSelectedItem() {
        guard let selectedTreeItemID else {
            return
        }
        presentTrash(itemID: selectedTreeItemID)
    }

    func presentTrash(itemID: String) {
        guard canTrashItem(id: itemID) else {
            return
        }
        vaultItemCreationID = nil
        isNewNotePresented = false
        isNewFolderPresented = false
        vaultItemCreationState = .idle
        resetRenameState()
        trashTargetItemID = itemID
        vaultItemTrashState = .idle
        isTrashConfirmationPresented = true
    }

    func dismissTrashConfirmation() {
        guard vaultItemTrashState != .trashing else {
            return
        }
        resetTrashState()
    }

    func confirmTrash(itemID: String) async {
        guard canTrashItem(id: itemID),
            case .loaded(let tree) = vaultTreeState
        else {
            return
        }
        trashTargetItemID = itemID
        let affectedIDs = Self.itemIDs(in: tree.root, rootedAt: itemID)
        let trashID = UUID()
        let generation = authenticationGeneration
        vaultItemTrashID = trashID
        trashAffectedItemIDs = affectedIDs
        trashVaultTree = tree
        isTrashConfirmationPresented = false
        vaultItemTrashState = .trashing

        do {
            let result = try await vaultItemTrasher.trash(
                itemID: itemID,
                in: tree,
                softTrashFolderID: selectedVault?.softTrashFolderID
            )
            guard vaultItemTrashID == trashID,
                authenticationGeneration == generation
            else {
                return
            }
            if let softTrashFolderID = result.softTrashFolderID {
                await persistSoftTrashFolderID(
                    softTrashFolderID,
                    vaultRootFolderID: tree.root.item.id
                )
                guard vaultItemTrashID == trashID,
                    authenticationGeneration == generation,
                    selectedVault?.rootFolderID == tree.root.item.id
                else {
                    return
                }
            }
            await finishConfirmedTrash(affectedIDs: affectedIDs)
        } catch {
            guard vaultItemTrashID == trashID,
                authenticationGeneration == generation
            else {
                return
            }
            if let driveError = error as? DriveError,
                driveError == .writeStatusUnknown
            {
                vaultItemTrashState = .statusUnknown(driveError.localizedDescription)
            } else {
                vaultItemTrashState = .failed(error.localizedDescription)
            }
            isTrashErrorAlertPresented = true
            transitionToReauthenticationIfNeeded(error)
        }
    }

    func dismissTrashErrorAlert() async {
        isTrashErrorAlertPresented = false
        guard case .statusUnknown = vaultItemTrashState,
            let trashTargetItemID,
            let vaultItemTrashID
        else {
            resetTrashState()
            return
        }
        let generation = authenticationGeneration
        vaultItemTrashState = .reconciling
        do {
            guard let tree = trashVaultTree else {
                throw DriveError.writeStatusUnknown
            }
            let result = try await vaultItemTrasher.reconcile(
                itemID: trashTargetItemID,
                in: tree
            )
            guard self.vaultItemTrashID == vaultItemTrashID,
                authenticationGeneration == generation
            else {
                return
            }
            switch result {
            case .trashed:
                await finishConfirmedTrash(affectedIDs: trashAffectedItemIDs)
            case .vaultSoftTrashed(let folderID):
                await persistSoftTrashFolderID(
                    folderID,
                    vaultRootFolderID: tree.root.item.id
                )
                guard self.vaultItemTrashID == vaultItemTrashID,
                    authenticationGeneration == generation,
                    selectedVault?.rootFolderID == tree.root.item.id
                else {
                    return
                }
                await finishConfirmedTrash(affectedIDs: trashAffectedItemIDs)
            case .notTrashed:
                resetTrashState()
                await loadVaultTree()
            }
        } catch {
            guard self.vaultItemTrashID == vaultItemTrashID,
                authenticationGeneration == generation
            else {
                return
            }
            vaultItemTrashState = .statusUnknown(error.localizedDescription)
            isTrashErrorAlertPresented = true
            transitionToReauthenticationIfNeeded(error)
        }
    }

    func presentNewNote() {
        guard canCreateVaultItems else {
            return
        }
        vaultItemCreationState = .idle
        resetRenameState()
        isNewNotePresented = true
    }

    func presentNewFolder() {
        guard canCreateVaultItems else {
            return
        }
        vaultItemCreationState = .idle
        resetRenameState()
        isNewFolderPresented = true
    }

    func dismissItemCreation() {
        guard vaultItemCreationState != .creating else {
            return
        }
        vaultItemCreationID = nil
        isNewNotePresented = false
        isNewFolderPresented = false
        vaultItemCreationState = .idle
    }

    func createNewNote(name: String, parentFolderID: String) async {
        guard case .loaded(let tree) = vaultTreeState,
            vaultItemCreationState != .creating
        else {
            return
        }
        let creationID = UUID()
        let generation = authenticationGeneration
        vaultItemCreationID = creationID
        vaultItemCreationState = .creating

        do {
            let metadata = try await vaultItemCreator.createMarkdownFile(
                name: name,
                parentFolderID: parentFolderID,
                in: tree
            )
            guard vaultItemCreationID == creationID,
                authenticationGeneration == generation
            else {
                return
            }
            isNewNotePresented = false
            vaultItemCreationState = .idle
            await loadVaultTree()
            guard vaultItemCreationID == creationID,
                authenticationGeneration == generation,
                !hasDirtyDocument,
                case .loaded(let refreshedTree) = vaultTreeState,
                refreshedTree.markdownFile(id: metadata.item.id) != nil
            else {
                return
            }
            await loadDocument(fileID: metadata.item.id, from: refreshedTree)
        } catch {
            handleItemCreationError(error, creationID: creationID, generation: generation)
        }
    }

    func createNewFolder(name: String, parentFolderID: String) async {
        guard case .loaded(let tree) = vaultTreeState,
            vaultItemCreationState != .creating
        else {
            return
        }
        let creationID = UUID()
        let generation = authenticationGeneration
        vaultItemCreationID = creationID
        vaultItemCreationState = .creating

        do {
            _ = try await vaultItemCreator.createFolder(
                name: name,
                parentFolderID: parentFolderID,
                in: tree
            )
            guard vaultItemCreationID == creationID,
                authenticationGeneration == generation
            else {
                return
            }
            isNewFolderPresented = false
            vaultItemCreationState = .idle
            await loadVaultTree()
        } catch {
            handleItemCreationError(error, creationID: creationID, generation: generation)
        }
    }

    var hasDirtyDocument: Bool {
        guard case .loaded(let document) = documentState else {
            return false
        }
        return document.isDirty
    }

    var isDocumentEditingEnabled: Bool {
        guard isTrashStatusLocked,
            case .loaded(let document) = documentState
        else {
            return true
        }
        return !trashAffectedItemIDs.contains(document.fileID)
    }

    func setFolderExpanded(id: String, isExpanded: Bool) {
        if isExpanded {
            expandedFolderIDs.insert(id)
        } else {
            expandedFolderIDs.remove(id)
        }
    }

    var canSaveDocument: Bool {
        guard hasDirtyDocument, documentSaveState != .saving else {
            return false
        }
        if vaultItemRenameState == .renaming,
            case .loaded(let document) = documentState,
            renameTargetItemID == document.fileID
        {
            return false
        }
        if isTrashStatusLocked {
            return false
        }
        return true
    }

    func selectTreeItem(id: String?) async {
        guard let id else {
            cancelActiveDocumentLoad()
            selectedTreeItemID = nil
            return
        }
        guard case .loaded(let tree) = vaultTreeState,
            tree.markdownFile(id: id) != nil
        else {
            cancelActiveDocumentLoad()
            selectedTreeItemID = id
            return
        }

        if case .loaded(let document) = documentState,
            document.fileID == id
        {
            selectedTreeItemID = id
            return
        }
        if hasDirtyDocument {
            pendingDocumentFileID = id
            isDiscardConfirmationPresented = true
            return
        }
        await loadDocument(fileID: id, from: tree)
    }

    func confirmDiscardAndOpenPendingDocument() async {
        guard let pendingDocumentFileID,
            case .loaded(let tree) = vaultTreeState
        else {
            cancelPendingDocumentOpen()
            return
        }
        self.pendingDocumentFileID = nil
        isDiscardConfirmationPresented = false
        await loadDocument(fileID: pendingDocumentFileID, from: tree)
    }

    func cancelPendingDocumentOpen() {
        pendingDocumentFileID = nil
        isDiscardConfirmationPresented = false
    }

    func setDiscardConfirmationPresented(_ isPresented: Bool) {
        isDiscardConfirmationPresented = isPresented
    }

    func retryDocumentLoad() async {
        guard case .failed(let fileID, _) = documentState,
            case .loaded(let tree) = vaultTreeState
        else {
            return
        }
        await loadDocument(fileID: fileID, from: tree)
    }

    func updateDocumentText(_ text: String) {
        guard isDocumentEditingEnabled,
            case .loaded(var document) = documentState
        else {
            return
        }
        document.updateText(text)
        documentState = .loaded(document)
        switch documentSaveState {
        case .saved, .failed, .conflict, .reloadFailed, .statusUnknown:
            documentSaveState = .idle
        case .idle, .saving:
            break
        }
    }

    func saveDocument() async {
        guard canSaveDocument,
            case .loaded(let document) = documentState,
            case .loaded(let tree) = vaultTreeState
        else {
            return
        }

        let documentBeingSaved = document
        let generation = authenticationGeneration
        documentSaveState = .saving
        do {
            let savedDocument = try await vaultDocumentSaver.save(
                document: documentBeingSaved,
                in: tree
            )
            guard authenticationGeneration == generation,
                case .loaded(var currentDocument) = documentState,
                currentDocument.fileID == documentBeingSaved.fileID
            else {
                return
            }
            if currentDocument.text == documentBeingSaved.text {
                currentDocument = savedDocument
            } else {
                currentDocument.recordSavedText(
                    savedDocument.text,
                    revision: savedDocument.remoteRevision
                )
            }
            documentState = .loaded(currentDocument)
            documentSaveState = currentDocument.isDirty ? .idle : .saved
        } catch let error as DocumentSaveError {
            guard authenticationGeneration == generation else {
                return
            }
            handleSaveError(error, fileID: documentBeingSaved.fileID)
        } catch {
            guard authenticationGeneration == generation else {
                return
            }
            handleSaveError(.unexpected, fileID: documentBeingSaved.fileID)
        }
    }

    func dismissConflictAlert() {
        isConflictAlertPresented = false
    }

    func reloadRemoteDocumentAfterConflict() async {
        guard case .loaded(let document) = documentState,
            case .loaded(let tree) = vaultTreeState
        else {
            dismissConflictAlert()
            return
        }
        let documentBeingReloaded = document
        let generation = authenticationGeneration
        isConflictAlertPresented = false
        documentSaveState = .conflict

        do {
            let remoteDocument = try await vaultDocumentLoader.load(
                fileID: documentBeingReloaded.fileID,
                from: tree
            )
            guard authenticationGeneration == generation,
                case .loaded(let currentDocument) = documentState,
                currentDocument.fileID == documentBeingReloaded.fileID
            else {
                return
            }
            guard currentDocument == documentBeingReloaded else {
                handleReloadError(
                    message:
                        "The remote version was not applied because the document changed while it was loading. Your local edits are still available.",
                    fileID: documentBeingReloaded.fileID
                )
                return
            }

            documentState = .loaded(remoteDocument)
            selectedTreeItemID = remoteDocument.fileID
            documentSaveState = .idle
        } catch let error as AuthenticationError {
            guard authenticationGeneration == generation else {
                return
            }
            handleReloadError(
                message:
                    "The remote version could not be loaded. \(error.localizedDescription) Your local edits are still available.",
                fileID: documentBeingReloaded.fileID,
                authenticationError: error
            )
        } catch let error as DriveError {
            guard authenticationGeneration == generation else {
                return
            }
            let authenticationError: AuthenticationError? =
                error == .authenticationRequired ? .reauthenticationRequired : nil
            handleReloadError(
                message:
                    "The remote version could not be loaded. \(error.localizedDescription) Your local edits are still available.",
                fileID: documentBeingReloaded.fileID,
                authenticationError: authenticationError
            )
        } catch {
            guard authenticationGeneration == generation else {
                return
            }
            handleReloadError(
                message:
                    "The remote version could not be loaded. Your local edits are still available.",
                fileID: documentBeingReloaded.fileID
            )
        }
    }

    func saveConflictCopy() async {
        guard case .loaded(let document) = documentState,
            case .loaded(let tree) = vaultTreeState
        else {
            dismissConflictAlert()
            return
        }

        let documentBeingCopied = document
        let generation = authenticationGeneration
        isConflictAlertPresented = false
        documentSaveState = .saving
        do {
            let copy = try await vaultDocumentSaver.saveCopy(
                document: documentBeingCopied,
                name: Self.conflictCopyName(for: documentBeingCopied.name),
                in: tree
            )
            guard authenticationGeneration == generation,
                case .loaded(let currentDocument) = documentState,
                currentDocument.fileID == documentBeingCopied.fileID
            else {
                return
            }

            if currentDocument.text == documentBeingCopied.text {
                documentState = .loaded(copy)
                selectedTreeItemID = copy.fileID
                documentSaveState = .saved
            } else {
                documentSaveState = .idle
            }
            await loadVaultTree()
        } catch let error as DocumentSaveError {
            guard authenticationGeneration == generation else {
                return
            }
            handleSaveError(error, fileID: documentBeingCopied.fileID)
        } catch {
            guard authenticationGeneration == generation else {
                return
            }
            handleSaveError(.unexpected, fileID: documentBeingCopied.fileID)
        }
    }

    func overwriteConflictingDocument() async {
        guard case .loaded(let document) = documentState,
            case .loaded(let tree) = vaultTreeState
        else {
            dismissConflictAlert()
            return
        }

        let documentBeingSaved = document
        let generation = authenticationGeneration
        isConflictAlertPresented = false
        documentSaveState = .saving
        do {
            let savedDocument = try await vaultDocumentSaver.overwriteRemote(
                document: documentBeingSaved,
                in: tree
            )
            guard authenticationGeneration == generation,
                case .loaded(var currentDocument) = documentState,
                currentDocument.fileID == documentBeingSaved.fileID
            else {
                return
            }
            if currentDocument.text == documentBeingSaved.text {
                currentDocument = savedDocument
            } else {
                currentDocument.recordSavedText(
                    savedDocument.text,
                    revision: savedDocument.remoteRevision
                )
            }
            documentState = .loaded(currentDocument)
            documentSaveState = currentDocument.isDirty ? .idle : .saved
        } catch let error as DocumentSaveError {
            guard authenticationGeneration == generation else {
                return
            }
            handleSaveError(error, fileID: documentBeingSaved.fileID)
        } catch {
            guard authenticationGeneration == generation else {
                return
            }
            handleSaveError(.unexpected, fileID: documentBeingSaved.fileID)
        }
    }

    func dismissSaveErrorAlert() {
        isSaveErrorAlertPresented = false
    }

    private func handleSaveError(_ error: DocumentSaveError, fileID: String) {
        guard case .loaded(let currentDocument) = documentState,
            currentDocument.fileID == fileID
        else {
            return
        }

        switch error {
        case .authentication(let authenticationError):
            documentSaveState = .failed(error.localizedDescription)
            transitionToReauthentication(authenticationError)
        case .conflict:
            documentSaveState = .conflict
            isConflictAlertPresented = true
        case .updateStatusUnknown:
            documentSaveState = .statusUnknown(error.localizedDescription)
            isSaveErrorAlertPresented = true
        default:
            documentSaveState = .failed(error.localizedDescription)
            isSaveErrorAlertPresented = true
        }
    }

    private func handleReloadError(
        message: String,
        fileID: String,
        authenticationError: AuthenticationError? = nil
    ) {
        guard case .loaded(let currentDocument) = documentState,
            currentDocument.fileID == fileID
        else {
            return
        }

        documentSaveState = .reloadFailed(message)
        isSaveErrorAlertPresented = true
        if let authenticationError {
            transitionToReauthentication(authenticationError)
        }
    }

    private static func conflictCopyName(for originalName: String) -> String {
        let baseName = (originalName as NSString).deletingPathExtension
        let suffix = UUID().uuidString.prefix(8)
        return "\(baseName) (Conflict Copy \(suffix)).md"
    }

    private func loadDocument(fileID: String, from tree: VaultTree) async {
        let loadID = UUID()
        let generation = authenticationGeneration
        documentLoadID = loadID
        selectedTreeItemID = fileID
        documentState = .loading(fileID: fileID)
        documentSaveState = .idle
        do {
            let document = try await vaultDocumentLoader.load(fileID: fileID, from: tree)
            guard documentLoadID == loadID,
                authenticationGeneration == generation
            else {
                return
            }
            documentState = .loaded(document)
        } catch {
            guard documentLoadID == loadID,
                authenticationGeneration == generation
            else {
                return
            }
            documentState = .failed(fileID: fileID, message: error.localizedDescription)
            transitionToReauthenticationIfNeeded(error)
        }
    }

    private func clearDocument() {
        cancelActiveDocumentLoad()
        documentState = .idle
        documentSaveState = .idle
        selectedTreeItemID = nil
        expandedFolderIDs.removeAll()
        pendingDocumentFileID = nil
        isDiscardConfirmationPresented = false
        isConflictAlertPresented = false
        isSaveErrorAlertPresented = false
    }

    private func closeDocumentPreservingExpansion() {
        cancelActiveDocumentLoad()
        documentState = .idle
        documentSaveState = .idle
        selectedTreeItemID = nil
        pendingDocumentFileID = nil
        isDiscardConfirmationPresented = false
        isConflictAlertPresented = false
        isSaveErrorAlertPresented = false
    }

    private var isTrashStatusLocked: Bool {
        switch vaultItemTrashState {
        case .trashing, .reconciling, .statusUnknown:
            return true
        case .idle, .failed:
            return false
        }
    }

    private func finishConfirmedTrash(affectedIDs: Set<String>) async {
        if let selectedTreeItemID, affectedIDs.contains(selectedTreeItemID) {
            self.selectedTreeItemID = nil
        }
        switch documentState {
        case .loaded(let document) where affectedIDs.contains(document.fileID):
            closeDocumentPreservingExpansion()
        case .loading(let fileID) where affectedIDs.contains(fileID):
            closeDocumentPreservingExpansion()
        case .failed(let fileID, _) where affectedIDs.contains(fileID):
            closeDocumentPreservingExpansion()
        default:
            break
        }
        resetTrashState()
        await loadVaultTree()
    }

    private func persistSoftTrashFolderID(
        _ folderID: String,
        vaultRootFolderID: String
    ) async {
        guard var vault = selectedVault,
            vault.rootFolderID == vaultRootFolderID,
            vault.softTrashFolderID != folderID
        else {
            return
        }
        vault.softTrashFolderID = folderID
        selectedVault = vault
        do {
            try await vaultStore.saveVault(vault)
        } catch {
            vaultPersistenceError = "The app Trash folder selection could not be saved."
        }
    }

    private func handleItemCreationError(
        _ error: any Error,
        creationID: UUID,
        generation: UInt64
    ) {
        guard vaultItemCreationID == creationID,
            authenticationGeneration == generation
        else {
            return
        }
        if let driveError = error as? DriveError,
            driveError == .writeStatusUnknown
        {
            vaultItemCreationState = .statusUnknown(driveError.localizedDescription)
        } else {
            vaultItemCreationState = .failed(error.localizedDescription)
        }
        transitionToReauthenticationIfNeeded(error)
    }

    private static func folderDestinations(
        in node: DriveTreeNode,
        parentPath: String?
    ) -> [VaultFolderDestination] {
        guard node.item.kind == .folder else {
            return []
        }
        let path = parentPath.map { "\($0) / \(node.item.name)" } ?? node.item.name
        return [VaultFolderDestination(id: node.item.id, displayPath: path)]
            + node.children.flatMap {
                folderDestinations(in: $0, parentPath: path)
            }
    }

    private static func itemIDs(in node: DriveTreeNode, rootedAt targetID: String) -> Set<String> {
        if node.item.id == targetID {
            return Set([node.item.id] + node.children.flatMap { allItemIDs(in: $0) })
        }
        for child in node.children {
            let ids = itemIDs(in: child, rootedAt: targetID)
            if !ids.isEmpty {
                return ids
            }
        }
        return []
    }

    private static func allItemIDs(in node: DriveTreeNode) -> [String] {
        [node.item.id] + node.children.flatMap { allItemIDs(in: $0) }
    }

    private func cancelActiveDocumentLoad() {
        documentLoadID = nil
        if case .loading = documentState {
            documentState = .idle
            documentSaveState = .idle
            selectedTreeItemID = nil
        }
    }

    private func invalidateVaultLoads() {
        vaultRestoreID = nil
        vaultBrowserLoadID = nil
        vaultTreeLoadID = nil
    }

    private func transitionToReauthenticationIfNeeded(_ error: any Error) {
        if let authenticationError = error as? AuthenticationError,
            authenticationError == .reauthenticationRequired
        {
            transitionToReauthentication(authenticationError)
        } else if let driveError = error as? DriveError,
            driveError == .authenticationRequired
        {
            transitionToReauthentication(.reauthenticationRequired)
        }
    }

    private func resetRenameState() {
        vaultItemRenameID = nil
        renameTargetItemID = nil
        isRenamePresented = false
        vaultItemRenameState = .idle
    }

    private func resetTrashState() {
        vaultItemTrashID = nil
        trashTargetItemID = nil
        trashAffectedItemIDs = []
        trashVaultTree = nil
        isTrashConfirmationPresented = false
        isTrashErrorAlertPresented = false
        vaultItemTrashState = .idle
    }

    @discardableResult
    private func beginAuthenticationTransition() -> UInt64 {
        authenticationGeneration &+= 1
        invalidateOutstandingOperationsForAuthenticationChange()
        return authenticationGeneration
    }

    private func transitionToReauthentication(_ error: AuthenticationError) {
        _ = beginAuthenticationTransition()
        authenticationState = .failed(error)
    }

    private func invalidateOutstandingOperationsForAuthenticationChange() {
        let preserveDirtyDocument = hasDirtyDocument
        invalidateVaultLoads()
        cancelActiveDocumentLoad()
        if !preserveDirtyDocument {
            documentState = .idle
            documentSaveState = .idle
            selectedTreeItemID = nil
            isConflictAlertPresented = false
            isSaveErrorAlertPresented = false
        }
        pendingDocumentFileID = nil
        isDiscardConfirmationPresented = false
        isVaultBrowserPresented = false
        vaultBrowserState = .idle
        vaultItemCreationID = nil
        isNewNotePresented = false
        isNewFolderPresented = false
        vaultItemCreationState = .idle
        resetRenameState()
        resetTrashState()
        if preserveDirtyDocument, documentSaveState == .saving {
            documentSaveState = .idle
        }
    }
}
