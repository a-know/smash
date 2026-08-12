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

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var authenticationState: AuthenticationState
    @Published private(set) var selectedVault: Vault?
    @Published private(set) var vaultPersistenceError: String?
    @Published private(set) var vaultBrowserState: VaultBrowserState = .idle
    @Published private(set) var vaultTreeState: VaultTreeState = .idle
    @Published private(set) var documentState: DocumentState = .idle
    @Published private(set) var selectedTreeItemID: String?
    @Published private(set) var pendingDocumentFileID: String?
    @Published private(set) var isDiscardConfirmationPresented = false
    @Published private(set) var isVaultBrowserPresented = false

    private let authenticationController: AuthenticationController
    private let driveFolderBrowser: DriveFolderBrowser
    private let vaultTreeLoader: VaultTreeLoader
    private let vaultDocumentLoader: VaultDocumentLoader
    private let vaultStore: any VaultStore
    private var didAttemptRestore = false
    private var documentLoadID: UUID?

    init(
        authenticationController: AuthenticationController,
        driveFolderBrowser: DriveFolderBrowser,
        vaultTreeLoader: VaultTreeLoader,
        vaultDocumentLoader: VaultDocumentLoader,
        vaultStore: any VaultStore,
        initialAuthenticationState: AuthenticationState = .signedOut
    ) {
        self.authenticationController = authenticationController
        self.driveFolderBrowser = driveFolderBrowser
        self.vaultTreeLoader = vaultTreeLoader
        self.vaultDocumentLoader = vaultDocumentLoader
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
    }

    private func loadDocument(fileID: String, from tree: VaultTree) async {
        let loadID = UUID()
        documentLoadID = loadID
        selectedTreeItemID = fileID
        documentState = .loading(fileID: fileID)
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
        selectedTreeItemID = nil
        pendingDocumentFileID = nil
        isDiscardConfirmationPresented = false
    }
}
