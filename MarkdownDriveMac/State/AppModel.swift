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
    @Published private(set) var pendingDocumentFileID: String?
    @Published private(set) var isDiscardConfirmationPresented = false
    @Published private(set) var isConflictAlertPresented = false
    @Published private(set) var isSaveErrorAlertPresented = false
    @Published private(set) var isVaultBrowserPresented = false

    private let authenticationController: AuthenticationController
    private let driveFolderBrowser: DriveFolderBrowser
    private let vaultTreeLoader: VaultTreeLoader
    private let vaultDocumentLoader: VaultDocumentLoader
    private let vaultDocumentSaver: VaultDocumentSaver
    private let vaultStore: any VaultStore
    private var didAttemptRestore = false
    private var documentLoadID: UUID?

    init(
        authenticationController: AuthenticationController,
        driveFolderBrowser: DriveFolderBrowser,
        vaultTreeLoader: VaultTreeLoader,
        vaultDocumentLoader: VaultDocumentLoader,
        vaultDocumentSaver: VaultDocumentSaver,
        vaultStore: any VaultStore,
        initialAuthenticationState: AuthenticationState = .signedOut
    ) {
        self.authenticationController = authenticationController
        self.driveFolderBrowser = driveFolderBrowser
        self.vaultTreeLoader = vaultTreeLoader
        self.vaultDocumentLoader = vaultDocumentLoader
        self.vaultDocumentSaver = vaultDocumentSaver
        self.vaultStore = vaultStore
        authenticationState = initialAuthenticationState
    }

    func restoreSession() async {
        guard !didAttemptRestore else {
            return
        }
        didAttemptRestore = true
        authenticationState = .restoring
        authenticationState = await authenticationController.restoreSession()
        await restoreVaultIfAuthenticated()
    }

    func signIn() async {
        authenticationState = .signingIn
        authenticationState = await authenticationController.signIn()
        await restoreVaultIfAuthenticated()
    }

    func signOut() async {
        guard !hasDirtyDocument else {
            return
        }
        authenticationState = await authenticationController.signOut()
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
        do {
            let vault = try await driveFolderBrowser.makeVault()
            try await vaultStore.saveVault(vault)
            selectedVault = vault
            clearDocument()
            vaultPersistenceError = nil
            dismissVaultBrowser()
            await loadVaultTree()
        } catch {
            vaultBrowserState = .failed(error.localizedDescription)
        }
    }

    private func updateBrowserState(
        operation: () async throws -> DriveFolderBrowserSnapshot
    ) async {
        vaultBrowserState = .loading
        do {
            vaultBrowserState = .loaded(try await operation())
        } catch {
            vaultBrowserState = .failed(error.localizedDescription)
        }
    }

    private func restoreVaultIfAuthenticated() async {
        guard case .signedIn = authenticationState else {
            return
        }
        do {
            selectedVault = try await vaultStore.loadVault()
            vaultPersistenceError = nil
            await loadVaultTree()
        } catch {
            selectedVault = nil
            vaultPersistenceError = "The saved Vault selection could not be restored."
        }
    }

    func loadVaultTree() async {
        guard let selectedVault else {
            vaultTreeState = .idle
            return
        }
        vaultTreeState = .loading
        do {
            vaultTreeState = .loaded(
                try await vaultTreeLoader.load(vault: selectedVault)
            )
        } catch {
            vaultTreeState = .failed(error.localizedDescription)
        }
    }

    var hasDirtyDocument: Bool {
        guard case .loaded(let document) = documentState else {
            return false
        }
        return document.isDirty
    }

    var canSaveDocument: Bool {
        hasDirtyDocument && documentSaveState != .saving
    }

    func selectTreeItem(id: String?) async {
        guard let id else {
            selectedTreeItemID = nil
            return
        }
        guard case .loaded(let tree) = vaultTreeState,
            tree.markdownFile(id: id) != nil
        else {
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
        documentSaveState = .saving
        do {
            let savedDocument = try await vaultDocumentSaver.save(
                document: documentBeingSaved,
                in: tree
            )
            guard case .loaded(var currentDocument) = documentState,
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
            handleSaveError(error, fileID: documentBeingSaved.fileID)
        } catch {
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
        isConflictAlertPresented = false
        documentSaveState = .conflict

        do {
            let remoteDocument = try await vaultDocumentLoader.load(
                fileID: documentBeingReloaded.fileID,
                from: tree
            )
            guard case .loaded(let currentDocument) = documentState,
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
            handleReloadError(
                message:
                    "The remote version could not be loaded. \(error.localizedDescription) Your local edits are still available.",
                fileID: documentBeingReloaded.fileID,
                authenticationError: error
            )
        } catch let error as DriveError {
            let authenticationError: AuthenticationError? =
                error == .authenticationRequired ? .reauthenticationRequired : nil
            handleReloadError(
                message:
                    "The remote version could not be loaded. \(error.localizedDescription) Your local edits are still available.",
                fileID: documentBeingReloaded.fileID,
                authenticationError: authenticationError
            )
        } catch {
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
        isConflictAlertPresented = false
        documentSaveState = .saving
        do {
            let copy = try await vaultDocumentSaver.saveCopy(
                document: documentBeingCopied,
                name: Self.conflictCopyName(for: documentBeingCopied.name),
                in: tree
            )
            guard case .loaded(let currentDocument) = documentState,
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
            handleSaveError(error, fileID: documentBeingCopied.fileID)
        } catch {
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
        isConflictAlertPresented = false
        documentSaveState = .saving
        do {
            let savedDocument = try await vaultDocumentSaver.overwriteRemote(
                document: documentBeingSaved,
                in: tree
            )
            guard case .loaded(var currentDocument) = documentState,
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
            handleSaveError(error, fileID: documentBeingSaved.fileID)
        } catch {
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
            authenticationState = .failed(authenticationError)
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
            authenticationState = .failed(authenticationError)
        }
    }

    private static func conflictCopyName(for originalName: String) -> String {
        let baseName = (originalName as NSString).deletingPathExtension
        let suffix = UUID().uuidString.prefix(8)
        return "\(baseName) (Conflict Copy \(suffix)).md"
    }

    private func loadDocument(fileID: String, from tree: VaultTree) async {
        let loadID = UUID()
        documentLoadID = loadID
        selectedTreeItemID = fileID
        documentState = .loading(fileID: fileID)
        documentSaveState = .idle
        do {
            let document = try await vaultDocumentLoader.load(fileID: fileID, from: tree)
            guard documentLoadID == loadID else {
                return
            }
            documentState = .loaded(document)
        } catch {
            guard documentLoadID == loadID else {
                return
            }
            documentState = .failed(fileID: fileID, message: error.localizedDescription)
        }
    }

    private func clearDocument() {
        documentLoadID = nil
        documentState = .idle
        documentSaveState = .idle
        selectedTreeItemID = nil
        pendingDocumentFileID = nil
        isDiscardConfirmationPresented = false
        isConflictAlertPresented = false
        isSaveErrorAlertPresented = false
    }
}
