import Combine
import MarkdownDriveCore

enum VaultBrowserState: Equatable {
    case idle
    case loading
    case loaded(DriveFolderBrowserSnapshot)
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var authenticationState: AuthenticationState
    @Published private(set) var selectedVault: Vault?
    @Published private(set) var vaultBrowserState: VaultBrowserState = .idle
    @Published private(set) var isVaultBrowserPresented = false

    private let authenticationController: AuthenticationController
    private let driveFolderBrowser: DriveFolderBrowser
    private var didAttemptRestore = false

    init(
        authenticationController: AuthenticationController,
        driveFolderBrowser: DriveFolderBrowser,
        initialAuthenticationState: AuthenticationState = .signedOut
    ) {
        self.authenticationController = authenticationController
        self.driveFolderBrowser = driveFolderBrowser
        authenticationState = initialAuthenticationState
    }

    func restoreSession() async {
        guard !didAttemptRestore else {
            return
        }
        didAttemptRestore = true
        authenticationState = .restoring
        authenticationState = await authenticationController.restoreSession()
    }

    func signIn() async {
        authenticationState = .signingIn
        authenticationState = await authenticationController.signIn()
    }

    func signOut() async {
        authenticationState = await authenticationController.signOut()
        if authenticationState == .signedOut {
            selectedVault = nil
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
            selectedVault = try await driveFolderBrowser.makeVault()
            dismissVaultBrowser()
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
}
