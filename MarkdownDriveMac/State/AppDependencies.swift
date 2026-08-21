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
        let driveChangeCursorCoordinator = DriveChangeCursorCoordinator(
            accountClient: driveClient,
            changeClient: driveClient,
            cursorStore: UserDefaultsDriveChangeCursorStore()
        )
        let documentReadCache = FileMarkdownDocumentReadCache()
        return AppModel(
            authenticationController: authenticationController,
            driveFolderBrowser: DriveFolderBrowser(driveClient: driveClient),
            vaultTreeLoader: VaultTreeLoader(driveClient: driveClient),
            vaultDocumentLoader: VaultDocumentLoader(
                driveContentClient: driveClient,
                documentReadCache: documentReadCache
            ),
            vaultDocumentSaver: VaultDocumentSaver(driveWriteClient: driveClient),
            vaultItemCreator: VaultItemCreator(driveClient: driveClient),
            vaultItemRenamer: VaultItemRenamer(driveClient: driveClient),
            vaultItemTrasher: VaultItemTrasher(driveClient: driveClient),
            vaultStore: UserDefaultsVaultStore(),
            driveChangeCursorCoordinator: driveChangeCursorCoordinator,
            driveChangeReconciler: DriveChangeReconciler(driveItemClient: driveClient)
        )
    }
}
