import SwiftUI

struct MarkdownDocumentCommands: Commands {
    @ObservedObject var appModel: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                appModel.presentNewNote()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!appModel.canCreateVaultItems)

            Button("New Folder") {
                appModel.presentNewFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!appModel.canCreateVaultItems)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                Task {
                    await appModel.saveDocument()
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!appModel.canSaveDocument)
        }
    }
}
