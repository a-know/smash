import Combine
import MarkdownDriveCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var authenticationState: AuthenticationState

    private let authenticationController: AuthenticationController
    private var didAttemptRestore = false

    init(
        authenticationController: AuthenticationController,
        initialAuthenticationState: AuthenticationState = .signedOut
    ) {
        self.authenticationController = authenticationController
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
    }
}
