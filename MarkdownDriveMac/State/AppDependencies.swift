import MarkdownDriveCore

enum AppDependencies {
    static func makeAuthenticationController() -> AuthenticationController {
        AuthenticationController(service: GoogleAuthenticationService())
    }
}
