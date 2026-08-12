import MarkdownDriveCore

enum AppDependencies {
    @MainActor
    static func makeAppModel() -> AppModel {
        let authenticationController = AuthenticationController(
            service: GoogleAuthenticationService()
        )
        let driveClient = GoogleDriveAPIClient(
            accessTokenProvider: authenticationController
        )
        return AppModel(
            authenticationController: authenticationController,
            driveFolderBrowser: DriveFolderBrowser(driveClient: driveClient),
            vaultStore: UserDefaultsVaultStore()
        )
    }
}
