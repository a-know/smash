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

    private let authenticationController: AuthenticationController
    private let driveFolderBrowser: DriveFolderBrowser
    private let vaultTreeLoader: VaultTreeLoader
    private let vaultDocumentLoader: VaultDocumentLoader
    private let vaultDocumentSaver: VaultDocumentSaver
    private let vaultItemCreator: VaultItemCreator
    private let vaultStore: any VaultStore
    private var didAttemptRestore = false
    private var authenticationGeneration: UInt64 = 0
    private var vaultRestoreID: UUID?
    private var vaultBrowserLoadID: UUID?
    private var vaultTreeLoadID: UUID?
    private var documentLoadID: UUID?
    private var vaultItemCreationID: UUID?

    init(
        authenticationController: AuthenticationController,
        driveFolderBrowser: DriveFolderBrowser,
        vaultTreeLoader: VaultTreeLoader,
        vaultDocumentLoader: VaultDocumentLoader,
        vaultDocumentSaver: VaultDocumentSaver,
        vaultItemCreator: VaultItemCreator,
        vaultStore: any VaultStore,
        initialAuthenticationState: AuthenticationState = .signedOut
    ) {
        self.authenticationController = authenticationController
        self.driveFolderBrowser = driveFolderBrowser
        self.vaultTreeLoader = vaultTreeLoader
        self.vaultDocumentLoader = vaultDocumentLoader
        self.vaultDocumentSaver = vaultDocumentSaver
        self.vaultItemCreator = vaultItemCreator
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
        guard !hasDirtyDocument else {
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
        guard !hasDirtyDocument else {
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

    var canCreateVaultItems: Bool {
        guard case .signedIn = authenticationState,
            case .loaded = vaultTreeState,
            vaultItemCreationState != .creating
        else {
            return false
        }
        return true
    }

    var availableVaultFolders: [VaultFolderDestination] {
        guard case .loaded(let tree) = vaultTreeState else {
            return []
        }
        return Self.folderDestinations(in: tree.root, parentPath: nil)
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

    func presentNewNote() {
        guard canCreateVaultItems else {
            return
        }
        vaultItemCreationState = .idle
        isNewNotePresented = true
    }

    func presentNewFolder() {
        guard canCreateVaultItems else {
            return
        }
        vaultItemCreationState = .idle
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

    func setFolderExpanded(id: String, isExpanded: Bool) {
        if isExpanded {
            expandedFolderIDs.insert(id)
        } else {
            expandedFolderIDs.remove(id)
        }
    }

    var canSaveDocument: Bool {
        hasDirtyDocument && documentSaveState != .saving
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
        guard case .loaded(var document) = documentState else {
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
        if preserveDirtyDocument, documentSaveState == .saving {
            documentSaveState = .idle
        }
    }
}
