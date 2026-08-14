import AppKit
import SwiftUI

@main
struct MarkdownDriveApp: App {
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var appDelegate
    @StateObject private var appModel: AppModel

    init() {
        _appModel = StateObject(
            wrappedValue: AppDependencies.makeAppModel()
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appModel: appModel)
                .onAppear {
                    appDelegate.appModel = appModel
                }
                .task {
                    await appModel.restoreSession()
                }
        }
        .defaultSize(width: 1_000, height: 700)
        .commands {
            MarkdownEditorCommands()
            MarkdownDocumentCommands(appModel: appModel)
        }
    }
}

@MainActor
private final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    weak var appModel: AppModel?

    private var isTerminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appModel else {
            return .terminateNow
        }
        guard appModel.hasDirtyDocument else {
            return .terminateNow
        }
        guard appModel.documentSaveState != .saving else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "A Save Is Still in Progress"
            alert.informativeText =
                "Markdown Drive will stay open until you try to quit again after the save finishes."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .terminateCancel
        }
        guard !isTerminationPending else {
            return .terminateLater
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save your changes before quitting?"
        alert.informativeText =
            "If you quit without saving, the changes in the current document will be lost."
        let saveButton = alert.addButton(withTitle: "Save and Quit")
        saveButton.keyEquivalent = "\r"
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        let discardButton = alert.addButton(withTitle: "Quit Without Saving")
        discardButton.hasDestructiveAction = true

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            isTerminationPending = true
            Task { @MainActor [weak self, weak sender] in
                await appModel.saveDocument()
                let didSaveAllChanges = !appModel.hasDirtyDocument
                self?.isTerminationPending = false
                sender?.reply(toApplicationShouldTerminate: didSaveAllChanges)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
