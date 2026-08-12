import SwiftUI

@main
struct MarkdownDriveApp: App {
    @StateObject private var appModel: AppModel

    init() {
        _appModel = StateObject(
            wrappedValue: AppDependencies.makeAppModel()
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appModel: appModel)
                .task {
                    await appModel.restoreSession()
                }
        }
        .defaultSize(width: 1_000, height: 700)
    }
}
