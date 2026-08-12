import Combine
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

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var authenticationState: AuthenticationState
    @Published private(set) var selectedVault: Vault?
    @Published private(set) var vaultPersistenceError: String?
    @Published private(set) var vaultBrowserState: VaultBrowserState = .idle
    @Published private(set) var vaultTreeState: VaultTreeState = .idle
    @Published private(set) var isVaultBrowserPresented = false

    private let authenticationController: AuthenticationController
    private let driveFolderBrowser: DriveFolderBrowser
    private let vaultTreeLoader: VaultTreeLoader
    private let vaultStore: any VaultStore
    private var didAttemptRestore = false

    init(
        authenticationController: AuthenticationController,
        driveFolderBrowser: DriveFolderBrowser,
        vaultTreeLoader: VaultTreeLoader,
        vaultStore: any VaultStore,
        initialAuthenticationState: AuthenticationState = .signedOut
    ) {
        self.authenticationController = authenticationController
        self.driveFolderBrowser = driveFolderBrowser
        self.vaultTreeLoader = vaultTreeLoader
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
        authenticationState = await authenticationController.signOut()
        if authenticationState == .signedOut {
            selectedVault = nil
            vaultTreeState = .idle
            dismissVaultBrowser()
        }
    }

    func presentVaultBrowser() async {
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
        do {
            let vault = try await driveFolderBrowser.makeVault()
            try await vaultStore.saveVault(vault)
            selectedVault = vault
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
}
